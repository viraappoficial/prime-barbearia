-- ST-3b.5 — plano/assinatura da carteira do staff.
--
-- staff_crm_atualizar_plano(p_ref, p_acao, p_tier)
--   p_acao: 'ativar' (p_tier 0|1|2) | 'registrar_corte' | 'cancelar'
--
-- Decisões (docs/investigacoes/14-staff-st3b5-plano.md, D-ST3b5-1/2):
--   • catálogo de planos FIXO no servidor (paridade com PLAN_TIERS do
--     legado): 0=Bronze(2 cortes, R$99,90) 1=Prata(4, R$189,90)
--     2=Ouro(4, R$289,90).
--   • D-ST3b5-1: ativar plano GRAVA venda de comissão em `sales`
--     (paridade completa com `baAssignPlan` — o legado sempre fez isso).
--   • D-ST3b5-2: `plano` aparece pra TODO papel (admin/barbeiro/vendas) —
--     não é sensível como idade/observação interna (D-ST3-6).
--
-- Mesma fronteira de segurança do resto do ST-3b: só mexe na carteira
-- (`crm_clients`) do PRÓPRIO chamador — reusa `_crm_resolve_ref_own`
-- (mesma autorização de `staff_crm_atualizar_contato`: só cria carteira
-- nova se já atendeu o cliente, ou é admin/vendas).
--
-- `staff_crm_ficha` ganha o bloco `plano` (2ª metade deste arquivo).
--
-- Rollback:
--   drop function public.staff_crm_atualizar_plano(text, text, int);
--   alter table public.crm_access_log drop constraint crm_access_log_acao_check;
--   alter table public.crm_access_log add constraint crm_access_log_acao_check
--     check (acao in ('atualizar_contato', 'revelar_telefone', 'vincular_conta'));
--   -- e reaplicar 20260911000300_staff_crm_ficha_observacao.sql (sem plano).
-- Impacto no legado: nenhum — RPC nova; `sales` ganha linhas do MESMO tipo
-- (`type:'assinatura'`) que o legado já insere, mesmo schema, sem coluna nova.

alter table public.crm_access_log drop constraint crm_access_log_acao_check;
alter table public.crm_access_log add constraint crm_access_log_acao_check
  check (acao in ('atualizar_contato', 'revelar_telefone', 'vincular_conta', 'atualizar_plano'));

create or replace function public.staff_crm_atualizar_plano(
  p_ref  text,
  p_acao text,
  p_tier int default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid       uuid := auth.uid();
  v_client_id uuid;
  v_crm       public.crm_clients%rowtype;
  v_rr        record;
  v_tz        text;
  v_now       timestamp;
  v_plano     jsonb;
  v_tier_nome text;
  v_tier_cuts int;
  v_tier_valor numeric;
  v_renova    date;
  v_nota      bigint;
begin
  if p_acao not in ('ativar', 'registrar_corte', 'cancelar') then
    raise exception 'BAD_INPUT' using errcode = 'P0001';
  end if;

  select * into v_rr from public._crm_resolve_ref_own(p_ref);
  v_client_id := v_rr.o_client_id;
  v_crm := v_rr.o_crm;

  if v_crm.id is null then
    -- mesma regra de staff_crm_atualizar_contato: 1ª escrita cria a carteira
    -- do chamador (só chegou até aqui se _crm_resolve_ref_own já autorizou).
    declare
      v_nome text;
    begin
      select coalesce(c.name, c.email, 'Cliente') into v_nome
      from public.clients c where c.id = v_client_id;
      if v_nome is null then
        raise exception 'BAD_INPUT' using errcode = 'P0001';
      end if;
      begin
        insert into public.crm_clients (barber_id, client_id, name)
        values (v_uid, v_client_id, v_nome)
        returning * into v_crm;
      exception when unique_violation then
        raise exception 'WALKIN_CONFLICT' using errcode = 'P0001';
      end;
    end;
  end if;

  select timezone into v_tz from public.shop_settings where id = 1;
  v_now := now() at time zone coalesce(v_tz, 'America/Sao_Paulo');

  if p_acao = 'ativar' then
    if p_tier is null or p_tier not in (0, 1, 2) then
      raise exception 'BAD_INPUT' using errcode = 'P0001';
    end if;
    select t.nome, t.cuts, t.valor into v_tier_nome, v_tier_cuts, v_tier_valor
    from (values
      (0, 'Plano Bronze', 2, 99.90),
      (1, 'Plano Prata',  4, 189.90),
      (2, 'Plano Ouro',   4, 289.90)
    ) as t(idx, nome, cuts, valor)
    where t.idx = p_tier;

    v_renova := (date_trunc('month', v_now::date) + interval '1 month')::date;
    v_plano := jsonb_build_object(
      'name', v_tier_nome, 'total', v_tier_cuts, 'used', 0,
      'renewsOn', to_char(v_renova, 'DD/MM')
    );

    update public.crm_clients set plan = v_plano
      where id = v_crm.id and barber_id = v_uid;

    -- D-ST3b5-1: comissão da assinatura (paridade com baAssignPlan).
    v_nota := nextval('public.sales_nota_seq');
    insert into public.sales (barber_id, client_name, service, value, date, time, nota_id, type)
    values (v_uid, v_crm.name, 'Assinatura — ' || v_tier_nome, v_tier_valor,
            v_now::date, to_char(v_now, 'HH24:MI'), v_nota, 'assinatura');

  elsif p_acao = 'registrar_corte' then
    if v_crm.plan is null then
      raise exception 'PLAN_NAO_ATIVO' using errcode = 'P0001';
    end if;
    v_plano := v_crm.plan;
    if coalesce((v_plano ->> 'used')::int, 0) < coalesce((v_plano ->> 'total')::int, 0) then
      v_plano := jsonb_set(v_plano, '{used}', to_jsonb(coalesce((v_plano ->> 'used')::int, 0) + 1));
    end if;
    update public.crm_clients set plan = v_plano
      where id = v_crm.id and barber_id = v_uid;

  else -- cancelar
    if v_crm.plan is null then
      raise exception 'PLAN_NAO_ATIVO' using errcode = 'P0001';
    end if;
    v_plano := null;
    update public.crm_clients set plan = null
      where id = v_crm.id and barber_id = v_uid;
  end if;

  insert into public.crm_access_log (staff_id, ref, acao)
  values (v_uid, p_ref, 'atualizar_plano');

  if v_plano is null then
    return jsonb_build_object('ref', 'crm:' || v_crm.id::text, 'plano', null);
  end if;
  return jsonb_build_object(
    'ref', 'crm:' || v_crm.id::text,
    'plano', jsonb_build_object(
      'nome', v_plano ->> 'name',
      'usados', (v_plano ->> 'used')::int,
      'total', (v_plano ->> 'total')::int,
      'renova_em', v_plano ->> 'renewsOn'
    )
  );
end;
$$;

revoke execute on function public.staff_crm_atualizar_plano(text, text, int)
  from public, anon, authenticated, service_role;
grant execute on function public.staff_crm_atualizar_plano(text, text, int) to authenticated;
