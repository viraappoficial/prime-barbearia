-- ST-3b — edição segura do CRM de clientes do staff (proposta
-- `prime-next/docs/investigacoes/13-staff-st3b-crm-edicao.md`, decisões
-- D-ST3b-1/2/4 aprovadas por Gabriel em 11/09).
--
-- Correção de desenho em relação à proposta: o documento cogitava reusar
-- `_staff_resolve_client_ref` (ST-2) para "vincular walk-in↔conta", mas essa
-- função NUNCA escreve `crm_clients.client_id` (resolve identidade pro
-- checkout, não liga carteira) — por isso `staff_crm_vincular_conta` abaixo é
-- uma RPC nova e pequena, não um wrapper.
--
-- Decisão de escopo tomada NA IMPLEMENTAÇÃO (não estava explícita na
-- proposta, registrada aqui): toda escrita desta fatia mexe **só na linha de
-- `crm_clients` do PRÓPRIO chamador** (`barber_id = auth.uid()`) — nunca na
-- tabela `clients` (conta real do cliente, ligada a `auth.users`/login).
-- Motivo: `crm_clients` é a "ficha particular" que cada membro do staff
-- mantém sobre um cliente (nome/telefone/observação **da perspectiva dele**);
-- `clients` é a conta real do cliente, e editar e-mail/telefone dela por um
-- barbeiro sem o cliente saber seria: (a) fora do escopo pedido ("editar
-- contato" na proposta falava da ficha do CRM, não da conta), (b)
-- potencialmente divergente de `auth.users.email` (login), (c) risco de
-- sequestro de conta se abusado. Para uma ref `conta:<uuid>` sem
-- `crm_clients` própria ainda, a RPC de edição CRIA uma linha de carteira
-- pro chamador (mesmo padrão do `_staff_resolve_client_ref` pro modo
-- walk-in) — nunca `UPDATE clients`.
--
-- Reflexo em D-ST3b-2: como toda escrita já é restrita a
-- `barber_id = auth.uid()` dentro do corpo da função (checado explicitamente,
-- não só pela RLS), o furo de `crm_clients_update_own` sem `WITH CHECK`
-- (RLS, exploitável só por REST direto fora da RPC) continua não sendo o
-- caminho usado pela app nova — fica registrado pro cutover como já decidido.
--
--   staff_crm_atualizar_contato(p_ref, p_campos)  — edita nome/telefone/
--     e-mail/instagram/idade/observação interna da carteira DO CHAMADOR
--   staff_crm_revelar_telefone(p_ref)             — telefone em claro +
--     log de acesso (mesma autorização de `staff_crm_ficha`: carteira OU
--     atendeu; admin/vendas livre)
--   staff_crm_vincular_conta(p_ref_walkin, p_conta_id) — liga um walk-in DA
--     CARTEIRA DO CHAMADOR a uma conta real
--
-- Todas: `security definer`, `search_path=''`, `_crm_ctx()` no início, erro
-- `P0001` + allow-list, `revoke all` + `grant authenticated`. Log append-only
-- em `crm_access_log` (nunca guarda o VALOR do campo, só quais mudaram).
--
-- Rollback:
--   drop function public.staff_crm_atualizar_contato(text, jsonb);
--   drop function public.staff_crm_revelar_telefone(text);
--   drop function public.staff_crm_vincular_conta(text, uuid);
--   drop table public.crm_access_log;
--   alter table public.crm_clients drop column observacao_interna;
-- Impacto no legado: nenhum — funções novas, coluna nova opcional
-- (`baOpenClientDetail` ignora colunas que não lê).

-- ── crm_clients.observacao_interna ──────────────────────────────────────────
alter table public.crm_clients
  add column if not exists observacao_interna text;

-- ── crm_access_log — append-only, nunca guarda o valor do campo ────────────
create table if not exists public.crm_access_log (
  id                bigint generated always as identity primary key,
  staff_id          uuid        not null references public.barbers(id),
  ref               text        not null,
  acao              text        not null check (acao in ('atualizar_contato', 'revelar_telefone', 'vincular_conta')),
  campos_alterados  text[],
  criado_em         timestamptz not null default now()
);

alter table public.crm_access_log enable row level security;
revoke all on public.crm_access_log from public, anon, authenticated, service_role;

do $$ begin
  create policy crm_access_log_select_own on public.crm_access_log
    for select to authenticated
    using (staff_id = auth.uid()
           or exists (select 1 from public.barbers b where b.id = auth.uid() and b.role = 'admin'));
exception when duplicate_object then null; end $$;
-- sem policy de INSERT/UPDATE/DELETE → só as RPCs (owner) escrevem.

-- ── helper: resolve ref (mesmo contrato de staff_crm_ficha) ────────────────
-- devolve o client_id da conta (se houver) e a linha de crm_clients JÁ DO
-- CHAMADOR (existente ou null) — owner-only, reusado pelas 3 RPCs de escrita.
create or replace function public._crm_resolve_ref_own(p_ref text, out o_client_id uuid, out o_crm public.crm_clients)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_role text := public._crm_ctx();
  v_kind text := split_part(coalesce(p_ref, ''), ':', 1);
  v_id   text := split_part(coalesce(p_ref, ''), ':', 2);
  v_cli  public.clients%rowtype;
begin
  if v_kind not in ('conta', 'crm') or v_id = '' then
    raise exception 'BAD_INPUT' using errcode = 'P0001';
  end if;

  if v_kind = 'conta' then
    if v_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'BAD_INPUT' using errcode = 'P0001';
    end if;
    select * into v_cli from public.clients where id = v_id::uuid;
    if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
    o_client_id := v_cli.id;
    select * into o_crm from public.crm_clients
      where client_id = o_client_id and barber_id = v_uid;
    -- sem carteira própria ainda para esta conta: só autoriza criar se o
    -- chamador já atendeu esse cliente (mesmo gate de `staff_crm_ficha`) ou
    -- é admin/vendas. Sem isso, qualquer barbeiro poderia "adotar" qualquer
    -- conta do sistema só chamando esta RPC com um uuid arbitrário.
    if o_crm.id is null and v_role = 'barbeiro' and not exists (
      select 1 from public.appointments a
      where a.client_id = o_client_id and a.barber_id = v_uid
    ) then
      raise exception 'NOT_FOUND' using errcode = 'P0001';
    end if;
  else
    if v_id !~ '^[0-9]+$' then
      raise exception 'BAD_INPUT' using errcode = 'P0001';
    end if;
    select * into o_crm from public.crm_clients where id = v_id::bigint;
    if not found or o_crm.barber_id <> v_uid then
      -- não vaza posse: ref de outra carteira responde igual a ref inexistente
      raise exception 'NOT_FOUND' using errcode = 'P0001';
    end if;
    o_client_id := o_crm.client_id;
  end if;
end;
$$;

revoke execute on function public._crm_resolve_ref_own(text)
  from public, anon, authenticated, service_role;

-- ── staff_crm_atualizar_contato ─────────────────────────────────────────────
create or replace function public.staff_crm_atualizar_contato(
  p_ref    text,
  p_campos jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid       uuid := auth.uid();
  v_role      text := public._crm_ctx();
  v_client_id uuid;
  v_crm       public.crm_clients%rowtype;
  v_key       text;
  v_val       text;
  v_changed   text[] := '{}';
  v_name      text;
  v_phone     text;
  v_email     text;
  v_instagram text;
  v_age       int;
  v_obs       text;
  v_has_name  boolean := false;
  v_rr        record;
begin
  if p_campos is null or jsonb_typeof(p_campos) <> 'object' or p_campos = '{}'::jsonb then
    raise exception 'BAD_INPUT' using errcode = 'P0001';
  end if;
  for v_key in select jsonb_object_keys(p_campos) loop
    if v_key not in ('name', 'phone', 'email', 'instagram', 'age', 'observacao_interna') then
      raise exception 'BAD_INPUT' using errcode = 'P0001';
    end if;
  end loop;

  select * into v_rr from public._crm_resolve_ref_own(p_ref);
  v_client_id := v_rr.o_client_id;
  v_crm := v_rr.o_crm;

  -- validação por campo (só os presentes)
  if p_campos ? 'name' then
    v_name := btrim(p_campos ->> 'name');
    if char_length(v_name) < 1 or char_length(v_name) > 80 then
      raise exception 'BAD_INPUT' using errcode = 'P0001';
    end if;
    v_has_name := true;
    v_changed := array_append(v_changed, 'name');
  end if;
  if p_campos ? 'phone' then
    v_val := p_campos ->> 'phone';
    v_phone := case when v_val is null or btrim(v_val) = '' then null
                     else public.normalize_phone_br(v_val) end;
    if v_val is not null and btrim(v_val) <> '' and (v_phone is null or v_phone !~ '^[0-9]{10,11}$') then
      raise exception 'BAD_INPUT' using errcode = 'P0001';
    end if;
    v_changed := array_append(v_changed, 'phone');
  end if;
  if p_campos ? 'email' then
    v_val := nullif(btrim(p_campos ->> 'email'), '');
    if v_val is not null and (char_length(v_val) > 254 or v_val !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') then
      raise exception 'BAD_INPUT' using errcode = 'P0001';
    end if;
    v_email := v_val;
    v_changed := array_append(v_changed, 'email');
  end if;
  if p_campos ? 'instagram' then
    v_instagram := nullif(btrim(p_campos ->> 'instagram'), '');
    if v_instagram is not null and char_length(v_instagram) > 60 then
      raise exception 'BAD_INPUT' using errcode = 'P0001';
    end if;
    v_changed := array_append(v_changed, 'instagram');
  end if;
  if p_campos ? 'age' then
    if jsonb_typeof(p_campos -> 'age') = 'null' then
      v_age := null;
    else
      begin
        v_age := (p_campos ->> 'age')::int;
      exception when others then
        raise exception 'BAD_INPUT' using errcode = 'P0001';
      end;
      if v_age < 0 or v_age > 119 then
        raise exception 'BAD_INPUT' using errcode = 'P0001';
      end if;
    end if;
    v_changed := array_append(v_changed, 'age');
  end if;
  if p_campos ? 'observacao_interna' then
    v_obs := nullif(btrim(p_campos ->> 'observacao_interna'), '');
    if v_obs is not null and char_length(v_obs) > 500 then
      raise exception 'BAD_INPUT' using errcode = 'P0001';
    end if;
    v_changed := array_append(v_changed, 'observacao_interna');
  end if;

  if v_crm.id is null then
    -- primeira edição desta carteira sobre este cliente: cria a linha.
    -- nome é NOT NULL — exige `name` no payload OU puxa da conta.
    if not v_has_name then
      if v_client_id is not null then
        select coalesce(c.name, c.email, 'Cliente') into v_name
        from public.clients c where c.id = v_client_id;
      else
        raise exception 'BAD_INPUT' using errcode = 'P0001';
      end if;
    end if;
    begin
      insert into public.crm_clients (barber_id, client_id, name, phone, email, age, instagram, observacao_interna)
      values (v_uid, v_client_id, v_name, v_phone, v_email, v_age, v_instagram, v_obs)
      returning * into v_crm;
    exception when unique_violation then
      -- já existe uma carteira do chamador com esse nome (índice
      -- `(barber_id, lower(name))`) — não é a mesma linha (v_crm.id era null).
      raise exception 'WALKIN_CONFLICT' using errcode = 'P0001';
    end;
  else
    update public.crm_clients set
      name               = coalesce(v_name, name),
      phone              = case when p_campos ? 'phone' then v_phone else phone end,
      email              = case when p_campos ? 'email' then v_email else email end,
      instagram          = case when p_campos ? 'instagram' then v_instagram else instagram end,
      age                = case when p_campos ? 'age' then v_age else age end,
      observacao_interna = case when p_campos ? 'observacao_interna' then v_obs else observacao_interna end
    where id = v_crm.id and barber_id = v_uid
    returning * into v_crm;
  end if;

  insert into public.crm_access_log (staff_id, ref, acao, campos_alterados)
  values (v_uid, p_ref, 'atualizar_contato', v_changed);

  return jsonb_build_object(
    'ref',                  'crm:' || v_crm.id::text,
    'telefone_masc',        public._mask_phone(v_crm.phone),
    'email_masc',           public._mask_email(v_crm.email),
    'instagram',            v_crm.instagram,
    'age',                  v_crm.age,
    'observacao_interna',   v_crm.observacao_interna
  );
end;
$$;

revoke execute on function public.staff_crm_atualizar_contato(text, jsonb)
  from public, anon, authenticated, service_role;
grant execute on function public.staff_crm_atualizar_contato(text, jsonb) to authenticated;

-- ── staff_crm_revelar_telefone ──────────────────────────────────────────────
-- mesma autorização de `staff_crm_ficha` (não a de "própria carteira só") —
-- é leitura pontual, não escrita: barbeiro pode revelar de quem atendeu, não
-- só da própria carteira.
create or replace function public.staff_crm_revelar_telefone(p_ref text)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_role text := public._crm_ctx();
  v_kind text := split_part(coalesce(p_ref, ''), ':', 1);
  v_id   text := split_part(coalesce(p_ref, ''), ':', 2);
  v_cli  public.clients%rowtype;
  v_crm  public.crm_clients%rowtype;
  v_cid  uuid;
  v_tel  text;
begin
  if v_kind not in ('conta', 'crm') or v_id = '' then
    raise exception 'BAD_INPUT' using errcode = 'P0001';
  end if;

  if v_kind = 'conta' then
    if v_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'BAD_INPUT' using errcode = 'P0001';
    end if;
    select * into v_cli from public.clients where id = v_id::uuid;
    if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
    v_cid := v_cli.id;
    select * into v_crm from public.crm_clients where client_id = v_cid and barber_id = v_uid;
  else
    if v_id !~ '^[0-9]+$' then
      raise exception 'BAD_INPUT' using errcode = 'P0001';
    end if;
    select * into v_crm from public.crm_clients where id = v_id::bigint;
    if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
    v_cid := v_crm.client_id;
  end if;

  if v_role = 'barbeiro' then
    if not (
         (v_crm.id is not null and v_crm.barber_id = v_uid)
      or (v_cid is not null and exists (
            select 1 from public.appointments a
            where a.client_id = v_cid and a.barber_id = v_uid))
    ) then
      raise exception 'NOT_FOUND' using errcode = 'P0001';
    end if;
  end if;

  v_tel := coalesce(v_cli.phone, v_crm.phone);

  insert into public.crm_access_log (staff_id, ref, acao)
  values (v_uid, p_ref, 'revelar_telefone');

  return v_tel;
end;
$$;

revoke execute on function public.staff_crm_revelar_telefone(text)
  from public, anon, authenticated, service_role;
grant execute on function public.staff_crm_revelar_telefone(text) to authenticated;

-- ── staff_crm_vincular_conta ────────────────────────────────────────────────
create or replace function public.staff_crm_vincular_conta(
  p_ref_walkin text,
  p_conta_id   uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_role text := public._crm_ctx();
  v_kind text := split_part(coalesce(p_ref_walkin, ''), ':', 1);
  v_id   text := split_part(coalesce(p_ref_walkin, ''), ':', 2);
  v_crm  public.crm_clients%rowtype;
  v_dup  bigint;
begin
  if v_kind <> 'crm' or v_id !~ '^[0-9]+$' then
    raise exception 'BAD_INPUT' using errcode = 'P0001';
  end if;
  if p_conta_id is null then
    raise exception 'BAD_INPUT' using errcode = 'P0001';
  end if;

  select * into v_crm from public.crm_clients where id = v_id::bigint;
  if not found or v_crm.barber_id <> v_uid then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
  if v_crm.client_id is not null then
    raise exception 'WALKIN_CONFLICT' using errcode = 'P0001';
  end if;

  if not exists (select 1 from public.clients where id = p_conta_id) then
    raise exception 'BAD_INPUT' using errcode = 'P0001';
  end if;

  -- a carteira já tem outra linha ligada a essa mesma conta? (evita duplicar
  -- o cliente na carteira do mesmo barbeiro)
  select id into v_dup from public.crm_clients
    where barber_id = v_uid and client_id = p_conta_id and id <> v_crm.id;
  if v_dup is not null then
    raise exception 'WALKIN_CONFLICT' using errcode = 'P0001';
  end if;

  update public.crm_clients set client_id = p_conta_id
    where id = v_crm.id and barber_id = v_uid
    returning * into v_crm;

  insert into public.crm_access_log (staff_id, ref, acao)
  values (v_uid, p_ref_walkin, 'vincular_conta');

  return jsonb_build_object('ref', 'crm:' || v_crm.id::text, 'client_id', v_crm.client_id);
end;
$$;

revoke execute on function public.staff_crm_vincular_conta(text, uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.staff_crm_vincular_conta(text, uuid) to authenticated;
