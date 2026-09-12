-- ST-3c.1 — revisão Codex (12/09): `staff_crm_marcar_indicacao_dada` grava
-- o mimo do lado ERRADO, e só conseguia marcar a indicação mais recente.
--
-- Achado #1 [P1]: a ficha mostra `indicado_por.mimo_dado` =
-- `referrer_gift_given` (o mimo do REFERENCIADOR) e `indicados[i].mimo_dado`
-- = `referred_gift_given` (o mimo do REFERENCIADO) — mas a RPC antiga
-- gravava o campo TROCADO em cada direção (`p_lado='indicou'` gravava
-- `referrer_gift_given` em vez de `referred_gift_given`, e vice-versa).
-- Resultado: a UI mostrava "mimo dado" sem o banco refletir isso.
--
-- Achado #2 [P2]: a RPC só operava na indicação mais recente
-- (`order by created_at desc limit 1`) — cliente com 2+ indicações não
-- conseguia marcar uma indicação antiga pendente se a mais nova já tivesse
-- sido marcada.
--
-- Fix: assinatura nova recebe `p_referral_id` explícito (a ficha agora
-- devolve o `id` de cada indicação/indicado — ver
-- `20260912000700_staff_crm_ficha_indicacao_fix.sql`); o campo a atualizar é
-- DERIVADO da relação real do cliente com essa linha (nunca mais recebido
-- do cliente): se `v_cid` é o referenciador da linha, marca o mimo do
-- REFERENCIADO (`referred_gift_given`); se é o referenciado, marca o mimo do
-- REFERENCIADOR (`referrer_gift_given`). Isso torna a troca de campo
-- estruturalmente impossível (não é mais um parâmetro que o cliente possa
-- inverter por engano).
--
-- Rollback:
--   drop function public.staff_crm_marcar_indicacao_dada(text, bigint);
--   -- e reaplicar 20260912000400_staff_crm_relacionamento.sql (função antiga).
-- Impacto no legado: nenhum.

drop function if exists public.staff_crm_marcar_indicacao_dada(text, text);

create or replace function public.staff_crm_marcar_indicacao_dada(
  p_ref         text,
  p_referral_id bigint
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
  v_lado text;
begin
  if p_referral_id is null then
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

  select * into v_ref_row from public.referrals where id = p_referral_id;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;

  -- a linha tem que pertencer a ESTE cliente (de um dos dois lados) — não
  -- vaza posse de indicação de outro cliente. O campo a marcar é o do
  -- OUTRO lado da relação (derivado, nunca recebido do cliente).
  if v_ref_row.referrer_client_id = v_cid then
    v_lado := 'indicou';
    update public.referrals set referred_gift_given = true where id = p_referral_id;
  elsif v_ref_row.referred_client_id = v_cid then
    v_lado := 'foi_indicado';
    update public.referrals set referrer_gift_given = true where id = p_referral_id;
  else
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;

  insert into public.crm_access_log (staff_id, ref, acao)
  values (v_uid, p_ref, 'marcar_indicacao');

  return jsonb_build_object('ref', p_ref, 'referral_id', p_referral_id, 'lado', v_lado);
end;
$$;

revoke execute on function public.staff_crm_marcar_indicacao_dada(text, bigint)
  from public, anon, authenticated, service_role;
grant execute on function public.staff_crm_marcar_indicacao_dada(text, bigint) to authenticated;
