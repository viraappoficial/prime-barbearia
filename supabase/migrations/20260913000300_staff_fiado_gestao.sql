-- ST-5.5 — A Prazo/Fiado (Gestão): gerar fatura, quitação, telefone do
-- cliente pra WhatsApp. `fiado_charges`/`fiado_invoices`/`sale_payments`
-- são "tabelas de venda/caixa" — o lint do app (`no-restricted-syntax`)
-- proíbe escrita direta nelas fora de `staff_checkout`/`staff_cart_*`,
-- então as 2 escritas desta fatia (gerar fatura, marcar fatura paga)
-- viram RPCs `security definer`, mesmo padrão do Caixa (ST-4.1/4.2).
-- `clients` também é proibido no código de staff (só RPCs de CRM) — o
-- telefone pro WhatsApp vira uma RPC própria, admin-only, com log em
-- `crm_access_log` (mesma tabela de auditoria de reveal de telefone já
-- usada por `staff_crm_revelar_telefone`, reaproveitada aqui: `ref` passa
-- a ser o `client_name` de `fiado_charges` pra este `acao`, não um "ref"
-- de CRM — documentado, sem alterar o schema da tabela de log).
--
-- Melhoria sobre o legado (não é regressão, é atomicidade real): o
-- legado faz "gerar fatura" e "marcar fatura paga" em 2-4 passos
-- sequenciais separados (insert fatura, depois update charges / insert
-- sale_payments, depois update charges, depois update invoice) — uma
-- falha no meio deixa dado inconsistente (fatura órfã sem charges
-- vinculadas, ou charges pagas sem sale_payments correspondente). Aqui
-- cada operação é UMA função (uma transação), tudo ou nada.
--
-- "Hoje" pra quitação (período fechado + paid_at) é computado no
-- SERVIDOR a partir de `shop_settings.timezone` — nunca aceito do
-- client (mesma razão da revisão Codex do ST-4.2: a data que decide uma
-- checagem de segurança/financeira não pode vir do relógio do
-- browser).
--
-- Rollback:
--   drop function public.staff_fiado_gerar_fatura(text);
--   drop function public.staff_fiado_marcar_pago(bigint, text);
--   drop function public.staff_fiado_telefone_cliente(text);
-- Impacto no legado: nenhum (RPCs novas, tabelas/policies existentes
-- inalteradas).

create or replace function public.staff_fiado_gerar_fatura(p_client_name text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := public._caixa_ctx();
  v_total numeric;
  v_ids bigint[];
  v_invoice_id bigint;
begin
  if p_client_name is null or length(trim(p_client_name)) = 0 then
    raise exception 'BAD_INPUT' using errcode = 'P0001';
  end if;

  select coalesce(sum(value), 0), array_agg(id)
    into v_total, v_ids
    from public.fiado_charges
    where client_name = p_client_name and status = 'aberto';

  if v_ids is null or array_length(v_ids, 1) is null then
    raise exception 'SEM_COBRANCA_ABERTA' using errcode = 'P0001';
  end if;

  insert into public.fiado_invoices (client_name, total, admin_id)
  values (p_client_name, v_total, v_uid)
  returning id into v_invoice_id;

  update public.fiado_charges
    set status = 'faturado', invoice_id = v_invoice_id
    where id = any(v_ids);

  return jsonb_build_object('id', v_invoice_id, 'client_name', p_client_name, 'total', v_total, 'status', 'faturado');
end;
$$;

create or replace function public.staff_fiado_marcar_pago(p_invoice_id bigint, p_method text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := public._caixa_ctx();
  v_tz    text;
  v_hoje  date;
  v_count int;
begin
  if p_method not in ('dinheiro', 'debito', 'credito', 'pix_qrs', 'pix_direto') then
    raise exception 'BAD_INPUT' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.fiado_invoices where id = p_invoice_id) then
    raise exception 'BAD_INPUT' using errcode = 'P0001';
  end if;

  select coalesce(timezone, 'America/Sao_Paulo') into v_tz from public.shop_settings where id = 1;
  v_hoje := (now() at time zone coalesce(v_tz, 'America/Sao_Paulo'))::date;

  if exists (select 1 from public.cash_closures where period_from <= v_hoje and period_to >= v_hoje) then
    raise exception 'PERIODO_FECHADO' using errcode = 'P0001';
  end if;

  insert into public.sale_payments (nota_id, barber_id, method, value)
    select nota_id, barber_id, p_method, value
    from public.fiado_charges
    where invoice_id = p_invoice_id;
  get diagnostics v_count = row_count;
  if v_count = 0 then
    raise exception 'SEM_COBRANCA_ABERTA' using errcode = 'P0001';
  end if;

  update public.fiado_charges
    set status = 'pago', paid_at = v_hoje, paid_method = p_method
    where invoice_id = p_invoice_id;

  update public.fiado_invoices set status = 'pago' where id = p_invoice_id;

  return jsonb_build_object('id', p_invoice_id, 'status', 'pago', 'paid_at', v_hoje);
end;
$$;

create or replace function public.staff_fiado_telefone_cliente(p_client_name text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := public._caixa_ctx();
  v_telefone text;
begin
  select phone into v_telefone
    from public.clients
    where name ilike p_client_name
    limit 1;

  insert into public.crm_access_log (staff_id, ref, acao)
    values (v_uid, coalesce(p_client_name, ''), 'revelar_telefone');

  return v_telefone;
end;
$$;

revoke execute on function public.staff_fiado_gerar_fatura(text) from public, anon, authenticated, service_role;
grant execute on function public.staff_fiado_gerar_fatura(text) to authenticated;
revoke execute on function public.staff_fiado_marcar_pago(bigint, text) from public, anon, authenticated, service_role;
grant execute on function public.staff_fiado_marcar_pago(bigint, text) to authenticated;
revoke execute on function public.staff_fiado_telefone_cliente(text) from public, anon, authenticated, service_role;
grant execute on function public.staff_fiado_telefone_cliente(text) to authenticated;
