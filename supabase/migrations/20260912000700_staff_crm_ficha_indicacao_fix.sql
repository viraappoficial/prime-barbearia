-- ST-3c.1 — revisão Codex (12/09): `indicado_por`/`indicados` ganham `id`
-- (referral_id), necessário pra `staff_crm_marcar_indicacao_dada(p_ref,
-- p_referral_id)` (ver `20260912000600_staff_crm_indicacao_fix.sql`) poder
-- mirar uma indicação ESPECÍFICA em vez de sempre a mais recente — fecha o
-- achado [P2] (cliente com 2+ indicações não conseguia marcar uma antiga
-- pendente se a mais nova já tivesse sido marcada).
--
-- Resto da função IDÊNTICO a `20260912000500_staff_crm_ficha_relacionamento.sql`
-- — só os 2 `jsonb_build_object` de indicação ganham a chave `id`.
--
-- Rollback: reaplicar `20260912000500_staff_crm_ficha_relacionamento.sql`.
-- Impacto no legado: nenhum.

create or replace function public.staff_crm_ficha(
  p_ref         text,
  p_hist_cursor text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_role   text := public._crm_ctx();
  v_kind   text := split_part(coalesce(p_ref, ''), ':', 1);
  v_id     text := split_part(coalesce(p_ref, ''), ':', 2);
  v_cli    public.clients%rowtype;
  v_crm    public.crm_clients%rowtype;
  v_cid    uuid;               -- conta (se houver)
  v_mname  text;               -- nome exato p/ casar walk-in por client_name
  v_scope  boolean := (v_role = 'barbeiro');   -- restringe ao próprio atendimento
  v_tz     text;
  v_hoje   date;
  v_hist   jsonb;
  v_hist_next text;
  v_before date;
  v_prox   jsonb;
  v_visitas int;
  v_svc    jsonb;
  v_barb   jsonb;
  v_plano  jsonb;
  v_brinde jsonb;
  v_indicacao jsonb;
  v_lg     public.loyalty_gifts%rowtype;
  v_indicado_por jsonb;
  v_indicados    jsonb;
begin
  if v_kind not in ('conta', 'crm') or v_id = '' then
    raise exception 'BAD_INPUT' using errcode = 'P0001';
  end if;

  -- resolve ref
  if v_kind = 'conta' then
    if v_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'BAD_INPUT' using errcode = 'P0001';
    end if;
    select * into v_cli from public.clients where id = v_id::uuid;
    if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
    v_cid := v_cli.id;
    select * into v_crm from public.crm_clients
      where client_id = v_cid and barber_id = v_uid;
  else
    if v_id !~ '^[0-9]+$' then
      raise exception 'BAD_INPUT' using errcode = 'P0001';
    end if;
    select * into v_crm from public.crm_clients where id = v_id::bigint;
    if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
    v_cid := v_crm.client_id;
    if v_cid is not null then
      select * into v_cli from public.clients where id = v_cid;
    end if;
  end if;

  -- autorização do barbeiro (admin/vendas: livre)
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

  -- chave de casamento do histórico
  v_mname := lower(coalesce(v_crm.name, v_cli.name, ''));

  -- ── histórico (keyset por dia; p_hist_cursor = 'YYYY-MM-DD' do último visto)
  if p_hist_cursor is not null and p_hist_cursor <> '' then
    if p_hist_cursor !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
      raise exception 'BAD_INPUT' using errcode = 'P0001';
    end if;
    v_before := p_hist_cursor::date;
  end if;

  with h as (
    select a.day, a.time, a.services, a.status,
           (select b.name from public.barbers b where b.id = a.barber_id) as barbeiro_nome,
           case when v_role = 'vendas' then null else a.notes end as notes
    from public.appointments a
    where a.status <> 'cancelado'
      and (not v_scope or a.barber_id = v_uid)
      and (
        (v_cid is not null and a.client_id = v_cid)
        or (v_cid is null and v_mname <> '' and lower(a.client_name) = v_mname
            and a.barber_id = coalesce(v_crm.barber_id, a.barber_id))
      )
      and (v_before is null or a.day < v_before)
    order by a.day desc, a.time desc
    limit 21
  ),
  hh as (select h.*, row_number() over (order by h.day desc, h.time desc) as rn from h)
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'day', hh.day, 'time', hh.time, 'services', hh.services,
      'barbeiro_nome', hh.barbeiro_nome, 'status', hh.status, 'notes', hh.notes
    ) order by hh.day desc, hh.time desc) filter (where hh.rn <= 20), '[]'::jsonb),
    case when bool_or(hh.rn = 21)
         then to_char(max(hh.day) filter (where hh.rn = 20), 'YYYY-MM-DD')
         else null end
  into v_hist, v_hist_next
  from hh;

  if p_hist_cursor is not null and p_hist_cursor <> '' then
    return jsonb_build_object('historico', v_hist, 'historico_next', v_hist_next);
  end if;

  -- ── próximo horário
  select timezone into v_tz from public.shop_settings where id = 1;
  v_hoje := (now() at time zone coalesce(v_tz, 'America/Sao_Paulo'))::date;

  select jsonb_build_object('day', a.day, 'time', a.time, 'services', a.services,
                            'barbeiro_nome', (select b.name from public.barbers b where b.id = a.barber_id))
  into v_prox
  from public.appointments a
  where a.status in ('pendente', 'confirmado')
    and a.day >= v_hoje
    and (not v_scope or a.barber_id = v_uid)
    and (
      (v_cid is not null and a.client_id = v_cid)
      or (v_cid is null and v_mname <> '' and lower(a.client_name) = v_mname
          and a.barber_id = coalesce(v_crm.barber_id, a.barber_id))
    )
  order by a.day, a.time
  limit 1;

  -- ── recorrência
  select count(*)::int into v_visitas
  from public.appointments a
  where a.status = 'concluido'
    and (not v_scope or a.barber_id = v_uid)
    and (
      (v_cid is not null and a.client_id = v_cid)
      or (v_cid is null and v_mname <> '' and lower(a.client_name) = v_mname
          and a.barber_id = coalesce(v_crm.barber_id, a.barber_id))
    );

  select coalesce(jsonb_agg(jsonb_build_object('nome', t.s, 'n', t.n) order by t.n desc, t.s), '[]'::jsonb)
  into v_svc
  from (
    select svc as s, count(*) as n
    from public.appointments a, unnest(a.services) svc
    where a.status = 'concluido'
      and (not v_scope or a.barber_id = v_uid)
      and (
        (v_cid is not null and a.client_id = v_cid)
        or (v_cid is null and v_mname <> '' and lower(a.client_name) = v_mname
            and a.barber_id = coalesce(v_crm.barber_id, a.barber_id))
      )
    group by svc order by n desc, svc limit 3
  ) t;

  if not v_scope and v_cid is not null then
    select jsonb_build_object('nome', b.name, 'n', t.n)
    into v_barb
    from (
      select a.barber_id, count(*) as n
      from public.appointments a
      where a.client_id = v_cid and a.status = 'concluido'
      group by a.barber_id order by n desc limit 1
    ) t join public.barbers b on b.id = t.barber_id;
  end if;

  if v_crm.plan is not null then
    v_plano := jsonb_build_object(
      'nome', v_crm.plan ->> 'name',
      'usados', (v_crm.plan ->> 'used')::int,
      'total', (v_crm.plan ->> 'total')::int,
      'renova_em', v_crm.plan ->> 'renewsOn'
    );
  end if;

  -- ── brinde (ST-3c.1) — só conta real; contagem via `visitas` (appointments,
  -- não `sales.client_name` — divergência deliberada de confiabilidade)
  if v_cid is not null then
    select * into v_lg from public.loyalty_gifts where client_id = v_cid;
    v_brinde := jsonb_build_object(
      'cortes',       v_visitas,
      'ultimo_marco', coalesce(v_lg.last_gift_at, 0),
      'proximo_marco', coalesce(v_lg.last_gift_at, 0) + 5,
      'elegivel',     v_visitas >= coalesce(v_lg.last_gift_at, 0) + 5,
      'escolha',      v_lg.choice
    );
  end if;

  -- ── indicação (ST-3c.1) — só conta real
  if v_cid is not null then
    select jsonb_build_object('id', r.id, 'nome', coalesce(c.name, c.email, 'Cliente'), 'mimo_dado', r.referrer_gift_given)
    into v_indicado_por
    from public.referrals r join public.clients c on c.id = r.referrer_client_id
    where r.referred_client_id = v_cid
    order by r.created_at desc limit 1;

    select coalesce(jsonb_agg(jsonb_build_object(
      'id', r.id, 'nome', coalesce(c.name, c.email, 'Cliente'), 'mimo_dado', r.referred_gift_given
    ) order by r.created_at desc), '[]'::jsonb)
    into v_indicados
    from public.referrals r join public.clients c on c.id = r.referred_client_id
    where r.referrer_client_id = v_cid;

    v_indicacao := jsonb_build_object('indicado_por', v_indicado_por, 'indicados', v_indicados);
  end if;

  return jsonb_build_object(
    'identificacao', jsonb_build_object(
      'nome',        coalesce(v_cli.name, v_cli.email, v_crm.name, 'Cliente'),
      'tipo',        case when v_cid is not null then 'conta' else 'walkin' end,
      'tem_conta',   v_cid is not null,
      'na_carteira', v_crm.id is not null and v_crm.barber_id = v_uid
    ),
    'contato', jsonb_build_object(
      'telefone_masc', public._mask_phone(coalesce(v_cli.phone, v_crm.phone)),
      'email_masc',    public._mask_email(coalesce(v_cli.email, v_crm.email)),
      'instagram',     coalesce(v_cli.instagram, v_crm.instagram),
      'age',           case when v_role = 'vendas' then null
                            else coalesce(v_cli.age, v_crm.age) end,
      'observacao_interna', case when v_role = 'vendas' then null else v_crm.observacao_interna end
    ),
    'plano', v_plano,
    'brinde', v_brinde,
    'indicacao', v_indicacao,
    'proximo', v_prox,
    'historico', v_hist,
    'historico_next', v_hist_next,
    'recorrencia', jsonb_build_object(
      'visitas',            v_visitas,
      'servicos_top',       v_svc,
      'barbeiro_top',       v_barb,
      'favorito_declarado', v_cli.favorite_barber
    )
  );
end;
$$;

revoke execute on function public.staff_crm_ficha(text, text)
  from public, anon, authenticated, service_role;
grant execute on function public.staff_crm_ficha(text, text) to authenticated;
