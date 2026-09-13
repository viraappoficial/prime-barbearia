-- ST-5.5 — revisão Codex: as 2 RPCs de escrita de A Prazo/Fiado
-- (`staff_fiado_gerar_fatura`/`staff_fiado_marcar_pago`) tinham corridas
-- reais entre chamadas concorrentes:
--
-- 1. `staff_fiado_gerar_fatura`: duas chamadas simultâneas pro MESMO
--    cliente liam o mesmo conjunto de cobranças `aberto` antes de
--    qualquer uma atualizar — as duas criavam uma fatura, e o segundo
--    UPDATE simplesmente reatribuía as cobranças pra sua própria fatura,
--    deixando a PRIMEIRA fatura órfã (sem nenhuma cobrança vinculada,
--    total>0, impossível de quitar).
-- 2. `staff_fiado_marcar_pago`: nada impedia quitar a MESMA fatura duas
--    vezes (dois cliques, duas abas, um retry) — cada chamada inseria
--    `sale_payments` de novo pras mesmas cobranças, duplicando o valor
--    que entra na fórmula de saldo do Caixa.
--
-- Fix: `pg_advisory_xact_lock` (mesmo padrão do trigger de último-admin,
-- ST-5.2) serializa chamadas concorrentes — a segunda só continua depois
-- que a primeira commitou, e nesse ponto vê o estado real (nenhuma
-- cobrança `aberto` sobrando / fatura já `pago`) e falha com o erro
-- correto em vez de duplicar dado.
--
-- Rollback: reaplicar a versão anterior das 2 funções (migration
-- staff_fiado_gestao.sql) via create or replace.
-- Impacto no legado: nenhum (RPCs novas desta fatia, ainda não
-- integradas em nenhuma branch merged).

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

  -- serializa gerar-fatura concorrente pro MESMO cliente — a segunda
  -- chamada só prossegue depois que a primeira commitou (ou desfez).
  perform pg_advisory_xact_lock(hashtext('fiado_gerar_fatura:' || p_client_name));

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
    where id = any(v_ids) and status = 'aberto';

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
  v_uid    uuid := public._caixa_ctx();
  v_tz     text;
  v_hoje   date;
  v_status text;
  v_count  int;
begin
  if p_method not in ('dinheiro', 'debito', 'credito', 'pix_qrs', 'pix_direto') then
    raise exception 'BAD_INPUT' using errcode = 'P0001';
  end if;

  -- serializa quitação concorrente da MESMA fatura (dois cliques, duas
  -- abas, retry) — a segunda chamada só prossegue depois que a primeira
  -- commitou, e nesse ponto a checagem de status abaixo já vê 'pago'.
  perform pg_advisory_xact_lock(hashtext('fiado_marcar_pago:' || p_invoice_id::text));

  select status into v_status from public.fiado_invoices where id = p_invoice_id;
  if v_status is null then
    raise exception 'BAD_INPUT' using errcode = 'P0001';
  end if;
  if v_status <> 'faturado' then
    raise exception 'FATURA_JA_PAGA' using errcode = 'P0001';
  end if;

  select coalesce(timezone, 'America/Sao_Paulo') into v_tz from public.shop_settings where id = 1;
  v_hoje := (now() at time zone coalesce(v_tz, 'America/Sao_Paulo'))::date;

  if exists (select 1 from public.cash_closures where period_from <= v_hoje and period_to >= v_hoje) then
    raise exception 'PERIODO_FECHADO' using errcode = 'P0001';
  end if;

  insert into public.sale_payments (nota_id, barber_id, method, value)
    select nota_id, barber_id, p_method, value
    from public.fiado_charges
    where invoice_id = p_invoice_id and status = 'faturado';
  get diagnostics v_count = row_count;
  if v_count = 0 then
    raise exception 'SEM_COBRANCA_ABERTA' using errcode = 'P0001';
  end if;

  update public.fiado_charges
    set status = 'pago', paid_at = v_hoje, paid_method = p_method
    where invoice_id = p_invoice_id and status = 'faturado';

  update public.fiado_invoices set status = 'pago' where id = p_invoice_id and status = 'faturado';

  return jsonb_build_object('id', p_invoice_id, 'status', 'pago', 'paid_at', v_hoje);
end;
$$;
