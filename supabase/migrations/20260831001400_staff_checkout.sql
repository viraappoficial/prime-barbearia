-- ST-2.5 — `staff_checkout`: a transação de fechamento de venda.
--
-- Proposta §4.3. Uma RPC = uma transação: venda (`sales`) + pagamento
-- (`sale_payments`) + fiado (`fiado_charges`) + estoque (`products`) + status do
-- atendimento + limpeza do carrinho + notificação, tudo-ou-nada.
--
-- Idempotência ATÔMICA: `_lock_checkout(p_idempotency_key)` ANTES de qualquer
-- leitura/escrita do log; releitura bloqueante; `request_fingerprint` +
-- reautorização no replay (§4.5).
--
-- Fonte de verdade única por caminho (D-ST2-16):
--   agenda (p_appt_id não-null): produtos SÓ de `cart_items`; serviço/desconto
--     SÓ do estado persistido por `staff_cart_set_services`. p_products /
--     p_service_ids / p_discount não-vazios → *_SOURCE_CONFLICT.
--   balcão (p_appt_id null): p_products / p_service_ids / p_discount são os
--     parâmetros.
--
-- Data da venda: SEMPRE do servidor no fuso da loja (§4.7). `p_date` não existe.
-- Período fechado: usa a data de FINALIZAÇÃO.
--
-- Rollback:
--   drop function public.staff_checkout(bigint,uuid,jsonb,bigint[],jsonb,jsonb,jsonb,text,uuid);
--   drop function public._staff_resolve_client_ref(uuid, jsonb);
--   drop table public.staff_checkout_log;
-- Impacto no legado: nenhum — `#barberApp` segue no fluxo de escritas soltas.

-- ── staff_checkout_log ─────────────────────────────────────────────────────
create table if not exists public.staff_checkout_log (
  idempotency_key     uuid primary key,
  nota_id             bigint      not null,
  appt_id             bigint,
  actor_id            uuid        not null,
  barber_id           uuid        not null,
  request_fingerprint text        not null,
  receipt             jsonb       not null,
  created_at          timestamptz not null default now()
);

alter table public.staff_checkout_log enable row level security;
revoke all on public.staff_checkout_log from public, anon, authenticated, service_role;
grant select on public.staff_checkout_log to authenticated;

do $$ begin
  -- `EXISTS (... role='admin')` inline (não `barber_role()`) — ver nota em ST-2.4.
  create policy staff_checkout_log_select_own on public.staff_checkout_log
    for select to authenticated
    using (actor_id = auth.uid() or barber_id = auth.uid()
           or exists (select 1 from public.barbers b where b.id = auth.uid() and b.role = 'admin'));
exception when duplicate_object then null; end $$;
-- sem policy de INSERT/UPDATE/DELETE → só a RPC (owner) escreve.

-- ── _staff_resolve_client_ref — contrato ST-1b.3 (balcão) ──────────────────
create or replace function public._staff_resolve_client_ref(p_barber_id uuid, p_ref jsonb)
returns table(o_client_id uuid, o_client_name text, o_client_email text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_mode           text;
  v_raw            text;
  v_name           text;
  v_phone          text;
  v_by_phone       bigint[];
  v_names_by_phone text[];
  v_by_name        bigint[];
  v_phones_by_name text[];
  v_crm_id         bigint;
begin
  if p_ref is null or jsonb_typeof(p_ref) <> 'object' then
    raise exception 'CLIENT_INVALID' using errcode = 'P0001';
  end if;
  v_mode := p_ref ->> 'mode';
  if v_mode is null or v_mode not in ('account', 'walkin') then
    raise exception 'CLIENT_INVALID' using errcode = 'P0001';
  end if;

  if v_mode = 'account' then
    v_raw := p_ref ->> 'id';
    if v_raw is null or v_raw !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'CLIENT_INVALID' using errcode = 'P0001';
    end if;
    o_client_id := v_raw::uuid;
    select coalesce(c.name, c.email, 'Cliente'), c.email
      into o_client_name, o_client_email
    from public.clients c where c.id = o_client_id;
    if not found then
      raise exception 'CLIENT_INVALID' using errcode = 'P0001';
    end if;
    return next; return;
  end if;

  v_name := btrim(coalesce(p_ref ->> 'name', ''));
  if char_length(v_name) < 1 or char_length(v_name) > 80 then
    raise exception 'WALKIN_INVALID' using errcode = 'P0001';
  end if;
  v_phone := public.normalize_phone_br(p_ref ->> 'phone');
  if v_phone is null or v_phone !~ '^[0-9]{10,11}$' then
    raise exception 'WALKIN_INVALID' using errcode = 'P0001';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('crm|' || p_barber_id::text || '|tel|' || v_phone, 0));
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('crm|' || p_barber_id::text || '|nom|' || lower(v_name), 0));

  select array_agg(id order by id), array_agg(name order by id)
    into v_by_phone, v_names_by_phone
  from public.crm_clients
  where barber_id = p_barber_id and phone is not null
    and public.normalize_phone_br(phone) = v_phone;

  if coalesce(cardinality(v_by_phone), 0) = 1 then
    if lower(v_names_by_phone[1]) <> lower(v_name) then
      raise exception 'WALKIN_CONFLICT' using errcode = 'P0001';
    end if;
    v_crm_id := v_by_phone[1];
  elsif coalesce(cardinality(v_by_phone), 0) > 1 then
    raise exception 'WALKIN_CONFLICT' using errcode = 'P0001';
  else
    select array_agg(id order by id), array_agg(phone order by id)
      into v_by_name, v_phones_by_name
    from public.crm_clients
    where barber_id = p_barber_id and lower(name) = lower(v_name);

    if coalesce(cardinality(v_by_name), 0) = 0 then
      insert into public.crm_clients (barber_id, name, phone)
      values (p_barber_id, v_name, v_phone) returning id into v_crm_id;
    elsif coalesce(cardinality(v_by_name), 0) = 1 then
      v_crm_id := v_by_name[1];
      if v_phones_by_name[1] is null then
        update public.crm_clients set phone = v_phone where id = v_crm_id;
      else
        raise exception 'WALKIN_CONFLICT' using errcode = 'P0001';
      end if;
    else
      raise exception 'WALKIN_CONFLICT' using errcode = 'P0001';
    end if;
  end if;

  o_client_id := null;
  o_client_name := v_name;
  o_client_email := null;
  return next;
end;
$$;

revoke execute on function public._staff_resolve_client_ref(uuid, jsonb)
  from public, anon, authenticated, service_role;

-- ── staff_checkout ─────────────────────────────────────────────────────────
create or replace function public.staff_checkout(
  p_appt_id         bigint   default null,
  p_barber_id       uuid     default null,
  p_client_ref      jsonb    default null,
  p_service_ids     bigint[] default null,
  p_discount        jsonb    default null,
  p_products        jsonb    default null,
  p_payments        jsonb    default null,
  p_notes           text     default null,
  p_idempotency_key uuid     default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor   uuid := auth.uid();
  v_role    text;
  v_log     public.staff_checkout_log%rowtype;
  v_fp      text;
  v_cfg     public.shop_settings%rowtype;
  v_now     timestamp;
  v_date    date;
  v_time    text;
  v_barber  uuid;
  v_appt    public.appointments%rowtype;
  v_appt_id bigint;
  v_client_id    uuid;
  v_client_name  text;
  v_client_email text;
  v_names   text[] := '{}';
  v_dur     int := 0;
  v_svc_tab numeric := 0;
  v_valor_servico numeric := 0;
  v_desc_abs numeric := 0;
  v_motivo  text;
  v_prod    jsonb := '[]'::jsonb;     -- linhas de produto resolvidas
  v_prod_total numeric := 0;
  v_total   numeric;
  v_disc    jsonb;
  d         record;
  v_el      jsonb;
  v_pid     bigint;
  v_q       int;
  v_prow    public.products%rowtype;
  v_recebido numeric := 0;
  v_dinheiro numeric := 0;
  v_excedente numeric;
  v_rest    numeric;
  v_cut     numeric;
  v_val     numeric;
  v_method  text;
  v_liq     jsonb := '[]'::jsonb;
  v_nota    bigint;
  v_lbl     text;
  v_receipt jsonb;
  v_pays_out jsonb := '[]'::jsonb;
begin
  if p_idempotency_key is null then raise exception 'BAD_INPUT' using errcode = 'P0001'; end if;
  if v_actor is null then raise exception 'NOT_AUTH' using errcode = 'P0001'; end if;
  v_role := public.barber_role();
  if v_role is null then raise exception 'NOT_STAFF' using errcode = 'P0001'; end if;

  v_fp := md5(coalesce(p_appt_id::text,'') || '§' || coalesce(p_barber_id::text,'') || '§' ||
    coalesce(p_client_ref::text,'') || '§' || coalesce(p_service_ids::text,'') || '§' ||
    coalesce(p_discount::text,'') || '§' || coalesce(p_products::text,'') || '§' ||
    coalesce(p_payments::text,'') || '§' || coalesce(p_notes,''));

  -- 1. REIVINDICAÇÃO ATÔMICA DA CHAVE
  perform public._lock_checkout(p_idempotency_key);
  select * into v_log from public.staff_checkout_log where idempotency_key = p_idempotency_key;
  if found then
    if v_fp <> v_log.request_fingerprint then
      raise exception 'IDEMPOTENCY_MISMATCH' using errcode = 'P0001';
    end if;
    if not (v_actor = v_log.actor_id
            or v_role in ('admin','vendas')
            or (v_role = 'barbeiro' and v_log.barber_id = v_actor)) then
      raise exception 'NOT_ALLOWED' using errcode = 'P0001';
    end if;
    return jsonb_set(v_log.receipt, '{status}', '"replayed"');
  end if;

  select * into v_cfg from public.shop_settings where id = 1;

  -- 2. caminho
  if p_appt_id is not null then
    -- ══ AGENDA ══
    if p_barber_id is not null or p_client_ref is not null then
      raise exception 'NOT_ALLOWED' using errcode = 'P0001';
    end if;
    if coalesce(cardinality(p_service_ids),0) > 0 then
      raise exception 'SERVICE_SOURCE_CONFLICT' using errcode = 'P0001';
    end if;
    if p_discount is not null then
      raise exception 'DISCOUNT_SOURCE_CONFLICT' using errcode = 'P0001';
    end if;
    if p_products is not null and jsonb_typeof(p_products) = 'array' and jsonb_array_length(p_products) > 0 then
      raise exception 'PRODUCT_SOURCE_CONFLICT' using errcode = 'P0001';
    end if;

    select barber_id into v_barber from public.appointments where id = p_appt_id;
    if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
    perform public._lock_agenda(v_barber, (select day from public.appointments where id = p_appt_id));
    v_appt := public._staff_appt_for_write_locked(p_appt_id, true);
    if v_appt.status = 'concluido' then
      raise exception 'ALREADY_CHECKED_OUT' using errcode = 'P0001';
    end if;
    if v_appt.status <> 'confirmado' or v_appt.iniciado_em is null then
      raise exception 'BAD_STATE' using errcode = 'P0001';
    end if;

    v_barber       := v_appt.barber_id;
    v_appt_id      := v_appt.id;
    v_client_id    := v_appt.client_id;
    v_client_name  := v_appt.client_name;
    v_names        := coalesce(v_appt.services, '{}'::text[]);

    select coalesce(sum(s.price),0) into v_svc_tab
    from public.services s where s.name = any(v_names);
    v_valor_servico := round(coalesce(v_appt.discount_price, v_svc_tab), 2);
    v_desc_abs      := round(v_svc_tab - v_valor_servico, 2);
    v_motivo        := v_appt.discount_motivo;

    for v_el in
      select jsonb_build_object('product_id', ci.product_id, 'name', p.name, 'qty', ci.qty,
             'price', p.price, 'category', coalesce(p.category,'Outros'), 'cost', coalesce(p.cost,0))
      from public.cart_items ci join public.products p on p.id = ci.product_id
      where ci.appointment_id = p_appt_id order by ci.id
      for update of ci, p
    loop
      v_prod := v_prod || v_el;
      v_prod_total := v_prod_total + round((v_el->>'price')::numeric * (v_el->>'qty')::int, 2);
    end loop;

  else
    -- ══ BALCÃO ══
    v_barber := coalesce(p_barber_id, v_actor);
    perform public._staff_can_book_for(v_barber, true);

    select o_client_id, o_client_name, o_client_email
      into v_client_id, v_client_name, v_client_email
    from public._staff_resolve_client_ref(v_barber, p_client_ref);

    if coalesce(cardinality(p_service_ids),0) > 0 then
      select o_names, o_dur, o_total into v_names, v_dur, v_svc_tab
      from public._validate_services_priced(p_service_ids);
      v_disc := coalesce(p_discount, '{"mode":"none"}'::jsonb);
      if (v_disc ->> 'mode') = 'coupon' then
        v_disc := v_disc || jsonb_build_object('service_ids', to_jsonb(p_service_ids));
      end if;
      select * into d from public._resolve_discount(v_role, v_disc, v_svc_tab);
      v_valor_servico := d.o_valor_servico;
      v_desc_abs      := d.o_desconto_abs;
      v_motivo        := d.o_motivo;
    else
      if p_discount is not null and coalesce(p_discount ->> 'mode','none') <> 'none' then
        raise exception 'DISCOUNT_NOT_ALLOWED' using errcode = 'P0001';
      end if;
    end if;

    if p_products is not null and jsonb_typeof(p_products) = 'array' then
      for v_el in select value from jsonb_array_elements(p_products) loop
        v_pid := (v_el ->> 'product_id')::bigint;
        v_q   := (v_el ->> 'qty')::int;
        if v_q is null or v_q <= 0 then raise exception 'BAD_QTY' using errcode = 'P0001'; end if;
        select * into v_prow from public.products where id = v_pid;
        if not found then raise exception 'PRODUCT_INVALID' using errcode = 'P0001'; end if;
        v_prod := v_prod || jsonb_build_object('product_id', v_prow.id, 'name', v_prow.name,
          'qty', v_q, 'price', v_prow.price, 'category', coalesce(v_prow.category,'Outros'),
          'cost', coalesce(v_prow.cost,0));
        v_prod_total := v_prod_total + round(v_prow.price * v_q, 2);
      end loop;
    end if;

    if v_client_id is not null and cardinality(v_names) > 0 then
      perform public._lock_agenda(v_barber, (now() at time zone v_cfg.timezone)::date);
      v_appt_id := public._staff_insert_completed_walkin_appt(
        v_barber, v_client_id, v_client_name, v_client_email, v_names, v_dur, p_notes);
    end if;
  end if;

  -- 3. total + data/hora
  if cardinality(v_names) = 0 and jsonb_array_length(v_prod) = 0 then
    raise exception 'BAD_INPUT' using errcode = 'P0001';
  end if;
  v_total := round(v_valor_servico + v_prod_total, 2);
  v_now   := now() at time zone v_cfg.timezone;
  v_date  := v_now::date;
  v_time  := to_char(v_now, 'HH24:MI');

  -- 4. período fechado (data de finalização)
  if exists (select 1 from public.cash_closures c
             where c.period_from <= v_date and c.period_to >= v_date) then
    raise exception 'PERIOD_CLOSED' using errcode = 'P0001';
  end if;

  -- 5. pagamentos
  if p_payments is null or jsonb_typeof(p_payments) <> 'array' or jsonb_array_length(p_payments) = 0 then
    raise exception 'PAYMENT_MISMATCH' using errcode = 'P0001';
  end if;
  for v_el in select value from jsonb_array_elements(p_payments) loop
    v_method := v_el ->> 'method';
    v_val    := round((v_el ->> 'value')::numeric, 2);
    if v_method not in ('dinheiro','debito','credito','pix_qrs','pix_direto','a_prazo')
       or v_val is null or v_val <= 0 then
      raise exception 'BAD_PAYMENT_METHOD' using errcode = 'P0001';
    end if;
    if v_method = 'a_prazo' and (
         (v_el ->> 'due_date') is null or (v_el ->> 'due_date')::date <= v_date) then
      raise exception 'FIADO_DUE_REQUIRED' using errcode = 'P0001';
    end if;
    v_recebido := v_recebido + v_val;
    if v_method = 'dinheiro' then v_dinheiro := v_dinheiro + v_val; end if;
  end loop;

  if v_recebido < v_total - 0.005 then
    raise exception 'PAYMENT_MISMATCH' using errcode = 'P0001';
  end if;
  v_excedente := round(v_recebido - v_total, 2);
  if v_excedente > 0.005 and v_dinheiro < v_excedente - 0.005 then
    raise exception 'PAYMENT_MISMATCH' using errcode = 'P0001';
  end if;

  v_rest := v_excedente;
  for v_el in select value from jsonb_array_elements(p_payments) loop
    v_method := v_el ->> 'method';
    v_val    := round((v_el ->> 'value')::numeric, 2);
    if v_method = 'dinheiro' and v_rest > 0.005 then
      v_cut  := least(v_rest, v_val);
      v_val  := round(v_val - v_cut, 2);
      v_rest := round(v_rest - v_cut, 2);
    end if;
    if v_val > 0.005 then
      v_liq := v_liq || jsonb_build_object(
        'method', v_method, 'value', v_val,
        'parcelas', case when v_method = 'credito' then coalesce((v_el ->> 'parcelas')::int, 1) else null end,
        'nsu', nullif(v_el ->> 'nsu',''), 'bandeira', nullif(v_el ->> 'bandeira',''),
        'due_date', v_el ->> 'due_date');
    end if;
  end loop;

  -- 6. nota_id
  v_nota := nextval('public.sales_nota_seq');

  -- 7. sales — linha de serviço
  if cardinality(v_names) > 0 then
    insert into public.sales
      (barber_id, client_name, appointment_id, service, value, date, time,
       nota_id, type, unit_price, discount, discount_motivo)
    values
      (v_barber, v_client_name, v_appt_id, array_to_string(v_names, ' + '),
       v_valor_servico, v_date, v_time, v_nota, null,
       round(v_svc_tab,2), round(v_desc_abs,2), v_motivo);
  end if;

  -- 7b. sales — linhas de produto
  for v_el in select value from jsonb_array_elements(v_prod) loop
    insert into public.sales
      (barber_id, client_name, appointment_id, service, value, qty, date, time,
       nota_id, type, category, cost, unit_price)
    values
      (v_barber, v_client_name, v_appt_id, v_el ->> 'name',
       round((v_el ->> 'price')::numeric * (v_el ->> 'qty')::int, 2),
       (v_el ->> 'qty')::int, v_date, v_time, v_nota, 'produto',
       v_el ->> 'category',
       round((v_el ->> 'cost')::numeric * (v_el ->> 'qty')::int, 2),
       (v_el ->> 'price')::numeric);
  end loop;

  -- 8. sale_payments (Σ = total)
  for v_el in select value from jsonb_array_elements(v_liq) loop
    insert into public.sale_payments (nota_id, barber_id, method, value, parcelas, nsu, bandeira)
    values (v_nota, v_barber, v_el ->> 'method', (v_el ->> 'value')::numeric,
            (v_el ->> 'parcelas')::int, v_el ->> 'nsu', v_el ->> 'bandeira');
    v_pays_out := v_pays_out || jsonb_build_object('method', v_el ->> 'method', 'value', (v_el ->> 'value')::numeric);
  end loop;

  -- 9. fiado_charges
  for v_el in select value from jsonb_array_elements(v_liq) loop
    if (v_el ->> 'method') = 'a_prazo' then
      insert into public.fiado_charges
        (nota_id, client_name, barber_id, value, sale_date, due_date, status)
      values
        (v_nota, v_client_name, v_barber, (v_el ->> 'value')::numeric,
         v_date, (v_el ->> 'due_date')::date, 'aberto');
    end if;
  end loop;

  -- 10. estoque (stock >= qty ou rollback)
  for v_el in select value from jsonb_array_elements(v_prod) loop
    update public.products set stock = stock - (v_el ->> 'qty')::int
      where id = (v_el ->> 'product_id')::bigint and stock >= (v_el ->> 'qty')::int;
    if not found then
      raise exception 'OUT_OF_STOCK' using errcode = 'P0001';
    end if;
  end loop;

  -- 11. status + limpa carrinho (agenda)
  if p_appt_id is not null then
    update public.appointments set status = 'concluido' where id = p_appt_id;
    delete from public.cart_items where appointment_id = p_appt_id;
  end if;

  -- 12. notificação (só conta)
  if v_client_id is not null then
    select day_label into v_lbl from public.appointments where id = coalesce(v_appt_id, -1);
    insert into public.notifications (for_role, recipient_client_id, type, appt_id, text)
    values ('client', v_client_id, 'concluido', v_appt_id,
            'Seu atendimento' || case when v_lbl is not null then ' de ' || v_lbl else '' end ||
            ' foi finalizado. Total R$ ' || to_char(v_total, 'FM999999990D00') || '.');
  end if;

  -- 13. receipt + log
  v_receipt := jsonb_build_object(
    'nota_id', v_nota, 'total', v_total, 'troco', v_excedente,
    'data', v_date, 'hora', v_time, 'appointment_id', v_appt_id,
    'servico', case when cardinality(v_names) > 0 then jsonb_build_object(
      'nome', array_to_string(v_names,' + '), 'tabela', round(v_svc_tab,2),
      'desconto', round(v_desc_abs,2), 'motivo', v_motivo, 'valor', v_valor_servico)
      else null end,
    'produtos', (select coalesce(jsonb_agg(jsonb_build_object(
        'nome', e ->> 'name', 'qty', (e ->> 'qty')::int,
        'subtotal', round((e ->> 'price')::numeric * (e ->> 'qty')::int, 2))), '[]'::jsonb)
      from jsonb_array_elements(v_prod) e),
    'pagamentos', v_pays_out,
    'status', 'ok');

  insert into public.staff_checkout_log
    (idempotency_key, nota_id, appt_id, actor_id, barber_id, request_fingerprint, receipt)
  values
    (p_idempotency_key, v_nota, v_appt_id, v_actor, v_barber, v_fp, v_receipt);

  return v_receipt;
end;
$$;

revoke execute on function public.staff_checkout(
  bigint, uuid, jsonb, bigint[], jsonb, jsonb, jsonb, text, uuid
) from public, anon, authenticated, service_role;
grant execute on function public.staff_checkout(
  bigint, uuid, jsonb, bigint[], jsonb, jsonb, jsonb, text, uuid
) to authenticated;
