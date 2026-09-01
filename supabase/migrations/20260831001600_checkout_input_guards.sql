-- ST-2.7 — hardening de entrada do checkout (guardas de tipo/formato JSON).
--
-- Incremental. NÃO altera as 6 migrations ST-2 já aplicadas no lab
-- (`20260831001000..1500`). Só `create or replace` das 2 funções que faziam
-- cast cru de valor vindo do cliente + 3 helpers puros novos.
--
-- Achado (pré-merge):
--   - `_resolve_discount` fazia `(p_discount ->> 'price')::numeric` e
--     `(p_discount ->> 'pct')::numeric` sem validar o tipo/forma do JSON:
--     texto ("abc") ou objeto/array → 22P02 cru vazado ao cliente; string
--     "NaN"/"Infinity" só era barrada por acidente (NaN > teto).
--   - `staff_checkout` fazia `(v_el ->> 'product_id')::bigint`,
--     `(v_el ->> 'qty')::int`, `(v_el ->> 'value')::numeric`,
--     `(v_el ->> 'due_date')::date` e `(v_el ->> 'parcelas')::int` crus:
--     payload REST malformado → 22P02/22007 cru, ou (pagamento "NaN" em
--     dinheiro) venda gravada com `sale_payments.value = NaN`.
--   - `p_products` não-null e não-array era silenciosamente ignorado.
--
-- Regra: validar tipo/forma do JSON ANTES de todo cast que venha do cliente;
-- erro de entrada = sempre `raise … using errcode = 'P0001'` com código da
-- allow-list que a UI já traduz (`traduzErroStaffVenda`): BAD_INPUT, BAD_QTY,
-- PRODUCT_INVALID, BAD_PAYMENT_METHOD, FIADO_DUE_REQUIRED, DISCOUNT_NOT_ALLOWED.
-- Nunca vazar 22P02 / 22007 / mensagem crua do Postgres.
--
-- Contratos válidos atuais preservados: a UI (`descontoParaRpc` /
-- `finalizarCheckout`) manda `price`/`pct`/`value`/`parcelas` como NÚMERO JSON
-- e `due_date` como string ISO `YYYY-MM-DD` — todos aceitos sem mudança.
--
-- Fora do alcance (registrado): parâmetros escalares/array TIPADOS da assinatura
-- (`p_service_ids bigint[]`, `p_idempotency_key uuid`) — malformados são
-- recusados pelo PostgREST na coerção de argumento ANTES do corpo rodar (400,
-- sem escrita parcial); mudá-los exigiria trocar o contrato (jsonb + parse),
-- o que está fora desta fatia.
--
-- Rollback:
--   -- restaura o corpo de `_resolve_discount` de 20260831001200 e o de
--   -- `staff_checkout` de 20260831001400 (create or replace de volta), depois:
--   drop function if exists public._checkout_num(jsonb, text);
--   drop function if exists public._checkout_int(jsonb, text, bigint, bigint);
--   drop function if exists public._checkout_date(jsonb, text);
-- Impacto no legado: nenhum — funções owner-only novas; as 2 RPCs mantêm
-- assinatura, retorno e grants (create or replace preserva os grants).

-- ══ helpers puros de parse defensivo ═══════════════════════════════════════
-- Todos: sem acesso a tabela, `search_path = ''`, `revoke` de toda role externa
-- (só as RPCs owner os chamam). Erro → `raise '%' , p_code using errcode='P0001'`.

-- _checkout_num — número finito a partir de JSON number OU string decimal limpa.
-- Rejeita: ausente/null, objeto, array, boolean, string não-decimal, "NaN",
-- "Infinity"/"-Infinity", e (defensivo) NaN/±Infinity já materializados.
create or replace function public._checkout_num(p_val jsonb, p_code text)
returns numeric
language plpgsql
immutable
security definer
set search_path = ''
as $$
declare
  v_t   text := jsonb_typeof(p_val);
  v_txt text;
  v_n   numeric;
begin
  if p_val is null or v_t is null then
    raise exception '%', p_code using errcode = 'P0001';
  end if;

  if v_t = 'number' then
    v_n := (p_val #>> '{}')::numeric;
  elsif v_t = 'string' then
    v_txt := p_val #>> '{}';
    if v_txt !~ '^-?[0-9]+(\.[0-9]+)?$' then      -- decimal simples; "NaN"/"1e5"/"" caem aqui
      raise exception '%', p_code using errcode = 'P0001';
    end if;
    v_n := v_txt::numeric;
  else                                            -- object / array / boolean / null
    raise exception '%', p_code using errcode = 'P0001';
  end if;

  if v_n is null
     or v_n = 'NaN'::numeric                       -- (numeric: NaN = NaN é true no PG)
     or v_n = 'Infinity'::numeric
     or v_n = '-Infinity'::numeric then
    raise exception '%', p_code using errcode = 'P0001';
  end if;
  return v_n;
end;
$$;

revoke execute on function public._checkout_num(jsonb, text)
  from public, anon, authenticated, service_role;

-- _checkout_int — inteiro em [p_min, p_max] a partir de JSON number/string.
-- Rejeita: ausente/null, não-inteiro (1.5, "1.5", "abc"), objeto/array/bool,
-- fora da faixa.
create or replace function public._checkout_int(p_val jsonb, p_code text, p_min bigint, p_max bigint)
returns bigint
language plpgsql
immutable
security definer
set search_path = ''
as $$
declare
  v_t   text := jsonb_typeof(p_val);
  v_txt text;
  v_n   numeric;
begin
  if p_val is null or v_t is null or v_t not in ('number', 'string') then
    raise exception '%', p_code using errcode = 'P0001';
  end if;
  v_txt := p_val #>> '{}';
  if v_txt !~ '^-?[0-9]+$' then
    raise exception '%', p_code using errcode = 'P0001';
  end if;
  v_n := v_txt::numeric;
  if v_n < p_min or v_n > p_max then
    raise exception '%', p_code using errcode = 'P0001';
  end if;
  return v_n::bigint;
end;
$$;

revoke execute on function public._checkout_int(jsonb, text, bigint, bigint)
  from public, anon, authenticated, service_role;

-- _checkout_date — date a partir de JSON string ISO estrita `YYYY-MM-DD`.
-- Rejeita: ausente/null, não-string, forma fora do ISO, e data fora de faixa
-- (`2026-13-40`) — o bloco `exception` traduz o 22007/22008 cru.
create or replace function public._checkout_date(p_val jsonb, p_code text)
returns date
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_txt text;
  v_d   date;
begin
  if p_val is null or jsonb_typeof(p_val) <> 'string' then
    raise exception '%', p_code using errcode = 'P0001';
  end if;
  v_txt := p_val #>> '{}';
  if v_txt !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    raise exception '%', p_code using errcode = 'P0001';
  end if;
  begin
    v_d := v_txt::date;
  exception when others then
    raise exception '%', p_code using errcode = 'P0001';
  end;
  return v_d;
end;
$$;

revoke execute on function public._checkout_date(jsonb, text)
  from public, anon, authenticated, service_role;

-- ══ _resolve_discount — guardas nos casts de manual.price / pct ═════════════
-- create or replace: corpo idêntico ao de 20260831001200 EXCETO
--   (1) rejeita p_discount não-objeto quando não-null → DISCOUNT_NOT_ALLOWED;
--   (2) `price`/`pct` via `_checkout_num(…, 'DISCOUNT_NOT_ALLOWED')`;
--   (3) `service_ids` do modo cupom só é iterado se for array JSON.
create or replace function public._resolve_discount(
  p_role      text,
  p_discount  jsonb,
  p_svc_total numeric
)
returns table(o_valor_servico numeric, o_desconto_abs numeric, o_pct numeric,
              o_motivo text, o_coupon_code text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_cfg    public.shop_settings%rowtype;
  v_mode   text;
  v_motivo text;
  v_cap    numeric;
  v_price  numeric;
  v_svc    numeric := round(coalesce(p_svc_total, 0), 2);
begin
  -- (1) payload de desconto malformado (texto/array/número/boolean) → recusa
  if p_discount is not null and jsonb_typeof(p_discount) <> 'object' then
    raise exception 'DISCOUNT_NOT_ALLOWED' using errcode = 'P0001';
  end if;

  v_mode   := coalesce(p_discount ->> 'mode', 'none');
  v_motivo := nullif(btrim(coalesce(p_discount ->> 'motivo', '')), '');

  -- sem serviço → nada a descontar
  if v_svc <= 0 then
    if v_mode <> 'none' then
      raise exception 'DISCOUNT_NOT_ALLOWED' using errcode = 'P0001';  -- não há serviço p/ descontar
    end if;
    o_valor_servico := 0; o_desconto_abs := 0; o_pct := 0; o_motivo := null; o_coupon_code := null;
    return next; return;
  end if;

  if v_mode = 'none' then
    o_valor_servico := v_svc; o_desconto_abs := 0; o_pct := 0; o_motivo := null; o_coupon_code := null;
    return next; return;
  end if;

  if v_mode = 'coupon' then
    -- _apply_coupon precisa dos IDs; o chamador passa via p_discount->'service_ids'
    v_price := public._apply_coupon(
      p_discount ->> 'code',
      (select coalesce(array_agg((e)::bigint), '{}'::bigint[])
         from jsonb_array_elements_text(
           case when jsonb_typeof(p_discount -> 'service_ids') = 'array'
                then p_discount -> 'service_ids' else '[]'::jsonb end) e));
    o_valor_servico := round(greatest(v_price, 0), 2);
    o_desconto_abs  := round(v_svc - o_valor_servico, 2);
    o_pct           := round(o_desconto_abs / v_svc * 100, 4);
    o_motivo        := null;                        -- cupom não exige motivo
    o_coupon_code   := upper(btrim(p_discount ->> 'code'));
    return next; return;
  end if;

  select * into v_cfg from public.shop_settings where id = 1;
  v_cap := case p_role
             when 'barbeiro' then v_cfg.max_discount_barbeiro
             when 'vendas'   then v_cfg.max_discount_vendas
             when 'admin'    then v_cfg.max_discount_admin
             else 0
           end;

  if v_mode = 'manual' then
    v_price := round(public._checkout_num(p_discount -> 'price', 'DISCOUNT_NOT_ALLOWED'), 2);
    o_desconto_abs := round(v_svc - v_price, 2);
    o_pct := round(o_desconto_abs / v_svc * 100, 4);
  elsif v_mode = 'pct' then
    o_pct := round(public._checkout_num(p_discount -> 'pct', 'DISCOUNT_NOT_ALLOWED'), 4);
    o_desconto_abs := round(v_svc * o_pct / 100, 2);
    v_price := round(v_svc - o_desconto_abs, 2);
  else
    raise exception 'DISCOUNT_NOT_ALLOWED' using errcode = 'P0001';  -- mode desconhecido
  end if;

  if o_pct < 0 then
    raise exception 'DISCOUNT_NOT_ALLOWED' using errcode = 'P0001';  -- acréscimo (D-ST2-2)
  end if;
  if o_pct > v_cap + 0.0001 then
    raise exception 'DISCOUNT_NOT_ALLOWED' using errcode = 'P0001';  -- acima do teto do papel
  end if;
  if o_pct > v_cfg.discount_motivo_threshold + 0.0001 and v_motivo is null then
    raise exception 'DISCOUNT_MOTIVO_REQUIRED' using errcode = 'P0001';
  end if;

  o_valor_servico := round(greatest(v_price, 0), 2);
  o_motivo := case when o_pct > v_cfg.discount_motivo_threshold + 0.0001 then left(v_motivo, 300) else null end;
  o_coupon_code := null;
  return next;
end;
$$;

revoke execute on function public._resolve_discount(text, jsonb, numeric)
  from public, anon, authenticated, service_role;

-- ══ staff_checkout — guardas nos casts de p_products / p_payments ═══════════
-- create or replace: corpo idêntico ao de 20260831001400 EXCETO
--   (A) guarda de container: p_products / p_payments não-null e não-array
--       → BAD_INPUT (antes de qualquer lock);
--   (B) balcão · item de p_products precisa ser objeto → BAD_INPUT;
--       product_id via `_checkout_int(…, 'PRODUCT_INVALID', 1, …)`;
--       qty via `_checkout_int(…, 'BAD_QTY', 1, …)` (cobre o `qty <= 0`);
--   (C) pagamentos · item precisa ser objeto → BAD_PAYMENT_METHOD;
--       value via `_checkout_num(…, 'BAD_PAYMENT_METHOD')` nos DOIS laços;
--       due_date via `_checkout_date(…, 'FIADO_DUE_REQUIRED')`;
--       parcelas via `_checkout_int(…, 'BAD_PAYMENT_METHOD', 1, 99)`;
--   (D) balcão sem serviço · p_discount não-objeto também → DISCOUNT_NOT_ALLOWED.
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

  -- (A) container malformado — antes de qualquer lock/escrita
  if p_products is not null and jsonb_typeof(p_products) <> 'array' then
    raise exception 'BAD_INPUT' using errcode = 'P0001';
  end if;
  if p_payments is not null and jsonb_typeof(p_payments) <> 'array' then
    raise exception 'BAD_INPUT' using errcode = 'P0001';
  end if;

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
      -- (D) sem serviço: só 'none' passa; payload não-objeto também recusa
      if p_discount is not null and (
           jsonb_typeof(p_discount) <> 'object'
           or coalesce(p_discount ->> 'mode','none') <> 'none') then
        raise exception 'DISCOUNT_NOT_ALLOWED' using errcode = 'P0001';
      end if;
    end if;

    if p_products is not null and jsonb_typeof(p_products) = 'array' then
      for v_el in select value from jsonb_array_elements(p_products) loop
        -- (B) item precisa ser objeto JSON
        if jsonb_typeof(v_el) <> 'object' then
          raise exception 'BAD_INPUT' using errcode = 'P0001';
        end if;
        v_pid := public._checkout_int(v_el -> 'product_id', 'PRODUCT_INVALID', 1, 9223372036854775807);
        v_q   := public._checkout_int(v_el -> 'qty', 'BAD_QTY', 1, 2147483647)::int;
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
    -- (C) item precisa ser objeto JSON
    if jsonb_typeof(v_el) <> 'object' then
      raise exception 'BAD_PAYMENT_METHOD' using errcode = 'P0001';
    end if;
    v_method := v_el ->> 'method';
    v_val    := round(public._checkout_num(v_el -> 'value', 'BAD_PAYMENT_METHOD'), 2);
    if v_method not in ('dinheiro','debito','credito','pix_qrs','pix_direto','a_prazo')
       or v_val is null or v_val <= 0 then
      raise exception 'BAD_PAYMENT_METHOD' using errcode = 'P0001';
    end if;
    if v_method = 'credito' and (v_el -> 'parcelas') is not null then
      perform public._checkout_int(v_el -> 'parcelas', 'BAD_PAYMENT_METHOD', 1, 99);
    end if;
    if v_method = 'a_prazo' and (
         (v_el -> 'due_date') is null
         or public._checkout_date(v_el -> 'due_date', 'FIADO_DUE_REQUIRED') <= v_date) then
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
    v_val    := round(public._checkout_num(v_el -> 'value', 'BAD_PAYMENT_METHOD'), 2);
    if v_method = 'dinheiro' and v_rest > 0.005 then
      v_cut  := least(v_rest, v_val);
      v_val  := round(v_val - v_cut, 2);
      v_rest := round(v_rest - v_cut, 2);
    end if;
    if v_val > 0.005 then
      v_liq := v_liq || jsonb_build_object(
        'method', v_method, 'value', v_val,
        'parcelas', case when v_method = 'credito'
          then coalesce(
            case when (v_el -> 'parcelas') is null then null
                 else public._checkout_int(v_el -> 'parcelas', 'BAD_PAYMENT_METHOD', 1, 99)::int end,
            1)
          else null end,
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
