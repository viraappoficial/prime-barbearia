-- ST-3c.1 — hardening de RLS de `loyalty_gifts`/`referrals` (D-ST3-9, parte
-- 1 de 2 — `appointment_waitlist` fica pra outra fatia, é fila por dia, não
-- por cliente, superfície diferente da ficha do CRM).
--
-- `docs/investigacoes/15-staff-st3c-relacionamento.md` §4 (ST-3c.1).
-- Mesmo princípio de D-ST3-1: RPC `SECURITY DEFINER` escopada AGORA pro
-- staff; a policy ampla (`loyalty_gifts_barber_all` / `referrals_select` /
-- `referrals_update_barber`, `EXISTS(barbers)` sem filtro de posse) **não é
-- tocada** nesta fatia — o CLIENTE também escreve nessas tabelas direto
-- (`primeSetBrindeChoice`, `primeCreateReferral`), fechar a RLS agora
-- quebraria o legado. Fecha de vez só no cutover, junto do resto.
--
-- Correção de contagem (decisão do Gabriel, 12/09): a elegibilidade do
-- brinde no legado conta `sales.client_name` (mesma base frágil rejeitada em
-- D-ST3-4 pro "gasto" — só 3/57 nomes batiam exato no lab). Aqui usa-se
-- `visitas` (contagem de `appointments` concluídos, já calculada em
-- `staff_crm_ficha`) — mais confiável, diverge numericamente do legado em
-- casos de nome inconsistente entre visitas.
--
-- Brinde/indicação só existem pra CONTA real (`loyalty_gifts`/`referrals`
-- são `client_id` NOT NULL, FK pra `clients`) — walk-in sem conta não
-- rastreia nenhum dos dois (mesmo comportamento do legado, `client.clientId`
-- obrigatório em `baRenderBrinde`).
--
--   staff_crm_marcar_brinde_dado(p_ref)             — marca mimo dado
--   staff_crm_marcar_indicacao_dada(p_ref, p_lado)   — p_lado: 'indicou' |
--                                                       'foi_indicado'
--
-- staff_crm_ficha ganha os blocos `brinde` e `indicacao` (visível a todo
-- papel — mesma decisão de D-ST3b5-2 pro plano; não é dado tão sensível
-- quanto idade/observação).
--
-- Rollback:
--   drop function public.staff_crm_marcar_brinde_dado(text);
--   drop function public.staff_crm_marcar_indicacao_dada(text, text);
--   alter table public.crm_access_log drop constraint crm_access_log_acao_check;
--   alter table public.crm_access_log add constraint crm_access_log_acao_check
--     check (acao in ('atualizar_contato', 'revelar_telefone', 'vincular_conta', 'atualizar_plano'));
--   -- e reaplicar 20260912000200_staff_crm_ficha_plano.sql (sem os blocos).
-- Impacto no legado: nenhum — RPCs novas; nenhuma policy/grant de
-- `loyalty_gifts`/`referrals` alterada.

alter table public.crm_access_log drop constraint crm_access_log_acao_check;
alter table public.crm_access_log add constraint crm_access_log_acao_check
  check (acao in ('atualizar_contato', 'revelar_telefone', 'vincular_conta',
                   'atualizar_plano', 'marcar_brinde', 'marcar_indicacao'));

-- ── staff_crm_marcar_brinde_dado ─────────────────────────────────────────
create or replace function public.staff_crm_marcar_brinde_dado(p_ref text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_role    text := public._crm_ctx();
  v_kind    text := split_part(coalesce(p_ref, ''), ':', 1);
  v_id      text := split_part(coalesce(p_ref, ''), ':', 2);
  v_cli     public.clients%rowtype;
  v_crm     public.crm_clients%rowtype;
  v_cid     uuid;
  v_visitas int;
  v_marco   int;
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

  if v_cid is null then
    raise exception 'BAD_INPUT' using errcode = 'P0001';  -- walk-in sem conta não rastreia brinde
  end if;

  select count(*)::int into v_visitas
  from public.appointments a
  where a.client_id = v_cid and a.status = 'concluido';

  v_marco := (v_visitas / 5) * 5;

  insert into public.loyalty_gifts (client_id, last_gift_at, given_on, choice)
  values (v_cid, v_marco, current_date, null)
  on conflict (client_id) do update
    set last_gift_at = v_marco, given_on = current_date, choice = null;

  insert into public.crm_access_log (staff_id, ref, acao)
  values (v_uid, p_ref, 'marcar_brinde');

  return jsonb_build_object('ref', p_ref, 'ultimo_marco', v_marco);
end;
$$;

revoke execute on function public.staff_crm_marcar_brinde_dado(text)
  from public, anon, authenticated, service_role;
grant execute on function public.staff_crm_marcar_brinde_dado(text) to authenticated;

-- ── staff_crm_marcar_indicacao_dada ──────────────────────────────────────
create or replace function public.staff_crm_marcar_indicacao_dada(
  p_ref  text,
  p_lado text
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
  v_kind text := split_part(coalesce(p_ref, ''), ':', 1);
  v_id   text := split_part(coalesce(p_ref, ''), ':', 2);
  v_cli  public.clients%rowtype;
  v_crm  public.crm_clients%rowtype;
  v_cid  uuid;
  v_ref_row public.referrals%rowtype;
begin
  if p_lado not in ('indicou', 'foi_indicado') then
    raise exception 'BAD_INPUT' using errcode = 'P0001';
  end if;
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

  if v_cid is null then
    raise exception 'BAD_INPUT' using errcode = 'P0001';
  end if;

  if p_lado = 'indicou' then
    select * into v_ref_row from public.referrals where referrer_client_id = v_cid
      order by created_at desc limit 1;
    if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
    update public.referrals set referrer_gift_given = true where id = v_ref_row.id;
  else
    select * into v_ref_row from public.referrals where referred_client_id = v_cid
      order by created_at desc limit 1;
    if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
    update public.referrals set referred_gift_given = true where id = v_ref_row.id;
  end if;

  insert into public.crm_access_log (staff_id, ref, acao)
  values (v_uid, p_ref, 'marcar_indicacao');

  return jsonb_build_object('ref', p_ref, 'referral_id', v_ref_row.id, 'lado', p_lado);
end;
$$;

revoke execute on function public.staff_crm_marcar_indicacao_dada(text, text)
  from public, anon, authenticated, service_role;
grant execute on function public.staff_crm_marcar_indicacao_dada(text, text) to authenticated;
