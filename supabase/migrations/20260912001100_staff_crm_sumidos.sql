-- ST-3c.4 — "sumiu há N dias": clientes sem cortar há 15+ dias, própria
-- carteira do barbeiro chamador.
--
-- No legado (`baFetchMyFollowups`/`baRenderSemCorteList`, index.html
-- ~5860-5924) isto é um FILTRO dentro da lista navegável de clientes
-- ("Todos os clientes" / "Vieram essa semana" / ... / "Sumidos"), lendo
-- direto de `haircut_followups` (mantida por uma rotina agendada no banco,
-- fora do escopo desta migration). O Prime Next não tem lista navegável de
-- clientes hoje (`/painel/clientes` é só busca) — decisão explícita do
-- Gabriel: página própria mínima (`/painel/clientes/sumidos`), sem
-- reconstruir a lista navegável inteira.
--
-- Escopo: SEMPRE `barber_id = auth.uid()` (a própria conta do chamador),
-- igual ao legado (`baCurrentBarberId`, não `baActingBarberId` — nem
-- admin "agindo como" outro barbeiro vê a lista de outro barbeiro aqui).
-- Sem branch de papel (admin/vendas não têm carteira própria de barbeiro
-- na prática — mesma limitação do legado, não uma regressão).
--
-- RLS de `haircut_followups` já restringe SELECT/UPDATE a
-- `barber_id = auth.uid()` (sem GAP — não precisou hardening, só RPC pra
-- manter o padrão de auditoria via `crm_access_log`).
--
-- Rollback:
--   drop function public.staff_crm_sumidos();
--   drop function public.staff_crm_marcar_sumido_contatado(bigint);
-- Impacto no legado: nenhum.

create or replace function public.staff_crm_sumidos()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  perform public._crm_ctx();

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', f.id,
      'nome', f.client_name,
      'telefone', f.client_phone,
      'ultimo_corte', f.last_cut_date,
      'dias', (current_date - f.last_cut_date),
      'contatado_em', f.contacted_at
    ) order by f.last_cut_date asc)
    from public.haircut_followups f
    where f.barber_id = v_uid
  ), '[]'::jsonb);
end;
$$;

create or replace function public.staff_crm_marcar_sumido_contatado(p_id bigint)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.haircut_followups%rowtype;
begin
  perform public._crm_ctx();

  if p_id is null then
    raise exception 'BAD_INPUT' using errcode = 'P0001';
  end if;

  select * into v_row from public.haircut_followups where id = p_id and barber_id = v_uid;
  if not found then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;

  update public.haircut_followups set contacted_at = now() where id = p_id;

  insert into public.crm_access_log (staff_id, ref, acao)
  values (v_uid, 'sumido:' || p_id, 'marcar_sumido_contatado');

  return jsonb_build_object('id', p_id, 'contatado_em', now());
end;
$$;

revoke execute on function public.staff_crm_sumidos() from public, anon, authenticated, service_role;
grant execute on function public.staff_crm_sumidos() to authenticated;
revoke execute on function public.staff_crm_marcar_sumido_contatado(bigint) from public, anon, authenticated, service_role;
grant execute on function public.staff_crm_marcar_sumido_contatado(bigint) to authenticated;

alter table public.crm_access_log drop constraint if exists crm_access_log_acao_check;
alter table public.crm_access_log add constraint crm_access_log_acao_check
  check (acao in (
    'atualizar_contato', 'revelar_telefone', 'vincular_conta',
    'atualizar_plano', 'marcar_brinde', 'marcar_indicacao', 'avaliar_cliente',
    'marcar_sumido_contatado'
  ));
