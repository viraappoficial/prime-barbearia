-- ST-3a.7 — escapar curingas de LIKE na busca do CRM (revisão Codex, 11/09).
--
-- Achado: `staff_crm_search`/`staff_lookup_account_for_booking` montam o
-- predicado de nome com `lower(...) like '%' || v_q || '%'` sem escapar `%`/
-- `_`. Um termo como `%%%` (passa no mínimo de 3 caracteres) vira
-- `like '%%%%%'` — casa qualquer nome — e permite enumerar, via cursor, toda
-- a base de clientes visível ao papel (não vaza fora do escopo de RLS/role,
-- mas derruba a intenção de "buscar por termo real", que é o freio contra
-- varredura em massa do CRM). O app novo (`prime-next`) já sanitiza o termo
-- antes de chamar a RPC (defesa em profundidade), mas qualquer chamada REST
-- direta autenticada ainda bate cru nas funções.
--
-- Fix: nova função privada `_crm_like_escape(text)` escapa `\`, `%` e `_`
-- (nessa ordem) antes de montar o padrão; os dois `LIKE` de busca por nome
-- passam a usar `ESCAPE '\'`. Busca por telefone já era imune — o termo passa
-- por `_crm_digits()` (só dígitos) antes de virar padrão.
--
-- `CREATE OR REPLACE` preserva os grants existentes das duas RPCs; só a nova
-- função privada precisa de `revoke`/sem grant externo (mesmo padrão de
-- `_crm_ctx`/`_mask_phone`/`_crm_digits`).
--
-- Rollback:
--   drop function public._crm_like_escape(text);
--   -- e reaplicar a versão anterior de staff_crm_search/
--   -- staff_lookup_account_for_booking (20260908000300_staff_crm_search.sql).
-- Impacto no legado: nenhum — só as 2 RPCs novas desta fatia, nunca aplicadas
-- em produção.

-- ── _crm_like_escape ─────────────────────────────────────────────────────
create or replace function public._crm_like_escape(p text)
returns text
language sql
immutable
security definer
set search_path = ''
as $$
  select replace(replace(replace(coalesce(p, ''), '\', '\\'), '%', '\%'), '_', '\_');
$$;

revoke execute on function public._crm_like_escape(text)
  from public, anon, authenticated, service_role;

-- ── staff_crm_search (name predicate ganha ESCAPE) ──────────────────────────
create or replace function public.staff_crm_search(
  p_q      text,
  p_cursor text default null,
  p_limit  int  default 20
)
returns table(
  ref                text,
  nome               text,
  telefone_masc      text,
  tipo               text,
  ultimo_atendimento date,
  na_carteira        boolean,
  next_cursor        text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_role   text := public._crm_ctx();
  v_q      text := btrim(coalesce(p_q, ''));
  v_dig    text := public._crm_digits(v_q);
  v_phone  boolean;
  v_name   text := lower(v_q);
  v_name_e text := public._crm_like_escape(lower(v_q));
  v_lim    int  := least(greatest(coalesce(p_limit, 20), 1), 20);
  v_ck     text;
  v_ck_nom text := '';
  v_ck_ref text := '';
begin
  if length(v_dig) >= 4 then
    v_phone := true;
  elsif length(v_q) >= 3 then
    v_phone := false;
  else
    return;  -- termo curto → nada, sem varrer
  end if;

  if p_cursor is not null and p_cursor <> '' then
    begin
      v_ck     := convert_from(decode(p_cursor, 'base64'), 'utf8');
      v_ck_nom := split_part(v_ck, chr(31), 1);
      v_ck_ref := split_part(v_ck, chr(31), 2);
      if v_ck_ref = '' then raise exception 'bad'; end if;
    exception when others then
      raise exception 'BAD_INPUT' using errcode = 'P0001';
    end;
  end if;

  return query
  with hits as (
    -- CONTAS visíveis ao papel
    select
      ('conta:' || c.id::text)                    as h_ref,
      coalesce(c.name, c.email, 'Cliente')        as h_nome,
      c.phone                                     as h_phone,
      'conta'::text                               as h_tipo,
      c.id                                        as h_cid,
      exists (
        select 1 from public.crm_clients cc
        where cc.client_id = c.id and cc.barber_id = v_uid
      )                                           as h_carteira
    from public.clients c
    where (
        v_role in ('admin', 'vendas')
        or exists (select 1 from public.appointments a
                   where a.client_id = c.id and a.barber_id = v_uid)
        or exists (select 1 from public.crm_clients cc
                   where cc.client_id = c.id and cc.barber_id = v_uid)
      )
      and (
        case when v_phone
          then regexp_replace(coalesce(c.phone, ''), '\D', '', 'g') like v_dig || '%'
            or regexp_replace(coalesce(c.phone, ''), '\D', '', 'g') like '55' || v_dig || '%'
          else lower(coalesce(c.name, '')) like '%' || v_name_e || '%' escape '\'
        end
      )

    union all

    -- WALK-INS (crm_clients sem client_id — linhas ligadas a conta aparecem
    -- acima, via `clients`, para de-dup)
    select
      ('crm:' || cc.id::text),
      cc.name,
      cc.phone,
      'walkin'::text,
      null::uuid,
      (cc.barber_id = v_uid)
    from public.crm_clients cc
    where cc.client_id is null
      and (v_role in ('admin', 'vendas') or cc.barber_id = v_uid)
      and (
        case when v_phone
          then regexp_replace(coalesce(cc.phone, ''), '\D', '', 'g') like v_dig || '%'
            or regexp_replace(coalesce(cc.phone, ''), '\D', '', 'g') like '55' || v_dig || '%'
          else lower(cc.name) like '%' || v_name_e || '%' escape '\'
        end
      )
  ),
  page as (
    select
      h.h_ref, h.h_nome, h.h_phone, h.h_tipo, h.h_cid, h.h_carteira,
      (
        select max(a.day) from public.appointments a
        where a.status <> 'cancelado'
          and (v_role in ('admin', 'vendas') or a.barber_id = v_uid)
          and (
            (h.h_cid is not null and a.client_id = h.h_cid)
            or (h.h_cid is null and lower(a.client_name) = lower(h.h_nome)
                and a.barber_id = v_uid)
          )
      ) as h_ultimo
    from hits h
    where (p_cursor is null or p_cursor = '')
       or (lower(h.h_nome), h.h_ref) > (v_ck_nom, v_ck_ref)
    order by lower(h.h_nome), h.h_ref
    limit v_lim + 1
  ),
  numbered as (
    select p.*, row_number() over (order by lower(p.h_nome), p.h_ref) as rn
    from page p
  )
  select
    n.h_ref,
    n.h_nome,
    public._mask_phone(n.h_phone),
    n.h_tipo,
    n.h_ultimo,
    n.h_carteira,
    case
      when (select count(*) from numbered) > v_lim and n.rn = v_lim
        then encode(convert_to(lower(n.h_nome) || chr(31) || n.h_ref, 'utf8'), 'base64')
      else null
    end
  from numbered n
  where n.rn <= v_lim
  order by lower(n.h_nome), n.h_ref;
end;
$$;

-- ── staff_lookup_account_for_booking (name predicate ganha ESCAPE) ─────────
create or replace function public.staff_lookup_account_for_booking(p_q text)
returns table(id uuid, nome text, telefone_masc text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_role text := public._crm_ctx();
  v_q    text := btrim(coalesce(p_q, ''));
  v_dig  text := public._crm_digits(v_q);
begin
  if length(v_dig) >= 4 then
    return query
      select c.id, coalesce(c.name, c.email, 'Cliente'), public._mask_phone(c.phone)
      from public.clients c
      where regexp_replace(coalesce(c.phone, ''), '\D', '', 'g') like v_dig || '%'
         or regexp_replace(coalesce(c.phone, ''), '\D', '', 'g') like '55' || v_dig || '%'
      order by c.name nulls last, c.id
      limit 5;
  elsif length(v_q) >= 3 then
    return query
      select c.id, coalesce(c.name, c.email, 'Cliente'), public._mask_phone(c.phone)
      from public.clients c
      where lower(coalesce(c.name, '')) like '%' || public._crm_like_escape(lower(v_q)) || '%' escape '\'
      order by c.name nulls last, c.id
      limit 5;
  else
    return;  -- termo curto → nada
  end if;
end;
$$;
