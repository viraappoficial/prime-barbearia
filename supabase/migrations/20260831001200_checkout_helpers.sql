-- ST-2.3 — helpers internos do checkout + hardening de RPCs de venda.
--
-- Todos `security definer`, `set search_path = ''`, objetos qualificados,
-- `plpgsql`/`sql` estático, erros `errcode='P0001'` da allowlist.
--   _validate_services_priced  — NOVA e SEPARADA (não toca a v1 usada por
--                                book_appointment / _staff_insert_appointment)
--   _apply_coupon              — math + escopo do cupom no servidor
--   _resolve_discount          — teto por papel + motivo obrigatório > threshold
--   _lock_checkout             — reivindicação atômica da idempotency_key
--   _staff_insert_completed_walkin_appt — atendimento concluído de balcão c/ conta
--   decrement_product_stock    — REESCRITO: P0001, search_path='', barber_role()
--   validate_coupon            — revoke anon (mantém authenticated)
--
-- Rollback (helpers primeiro, depois restauração):
--   drop function public._validate_services_priced(bigint[]);
--   drop function public._apply_coupon(text, bigint[]);
--   drop function public._resolve_discount(text, jsonb, numeric);
--   drop function public._lock_checkout(uuid);
--   drop function public._staff_insert_completed_walkin_appt(uuid,uuid,text,text,text[],int,text);
--   -- decrement_product_stock: CREATE OR REPLACE de volta ao corpo de 20260805* (baseline):
--   --   search_path='public', erros de texto cru, grant anon/authenticated/service_role
--   grant execute on function public.validate_coupon(text) to anon;
-- Impacto no legado: `decrement_product_stock` continua funcionando p/ staff
-- logado (barbeiro/admin/vendas) — `anon` perde o acesso (não usava); o wizard
-- do cliente logado ainda chama `validate_coupon` (grant `authenticated` mantido).

-- ══ _validate_services_priced ═══════════════════════════════════════════════
-- espelha _validate_services (lista não-vazia, sem duplicata, todos ativos) +
-- devolve o PREÇO de tabela (soma) além de nomes e duração.
create or replace function public._validate_services_priced(p_service_ids bigint[])
returns table(o_names text[], o_dur int, o_total numeric)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_card     int;
  v_distinct int;
  v_found    int;
begin
  select count(*), count(distinct e) into v_card, v_distinct
  from unnest(coalesce(p_service_ids, '{}'::bigint[])) e;

  if v_card = 0 or v_card <> v_distinct then
    raise exception 'SERVICE_INVALID' using errcode = 'P0001';
  end if;

  select array_agg(s.name order by s.display_order),
         sum(s.duration_min),
         sum(s.price),
         count(*)
    into o_names, o_dur, o_total, v_found
  from public.services s
  where s.id = any(p_service_ids) and s.active = true;

  if coalesce(v_found, 0) <> v_distinct then
    raise exception 'SERVICE_INVALID' using errcode = 'P0001';
  end if;

  o_total := round(coalesce(o_total, 0), 2);
  return next;
end;
$$;

revoke execute on function public._validate_services_priced(bigint[])
  from public, anon, authenticated, service_role;

-- ══ _apply_coupon ══════════════════════════════════════════════════════════
-- devolve o NOVO total do serviço (não o desconto) — paridade com
-- primeApplyCoupon. valor_fixo é clampado a [0, total] (o legado deixava
-- acréscimo passar — aqui não).
create or replace function public._apply_coupon(p_code text, p_service_ids bigint[])
returns numeric
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_c     public.coupons%rowtype;
  v_names text[];
  v_total numeric;
begin
  select * into v_c from public.coupons
    where code = upper(btrim(coalesce(p_code, ''))) and active = true;
  if not found then
    raise exception 'COUPON_INVALID' using errcode = 'P0001';
  end if;

  select array_agg(s.name order by s.id), sum(s.price)
    into v_names, v_total
  from public.services s
  where s.id = any(p_service_ids) and s.active = true;

  if coalesce(cardinality(v_names), 0) <> coalesce(cardinality(p_service_ids), 0)
     or coalesce(cardinality(p_service_ids), 0) = 0 then
    raise exception 'SERVICE_INVALID' using errcode = 'P0001';
  end if;

  -- cupom com escopo: só vale p/ EXATAMENTE 1 serviço e ele na lista
  if coalesce(cardinality(v_c.services), 0) > 0 then
    if cardinality(p_service_ids) <> 1 or not (v_names[1] = any(v_c.services)) then
      raise exception 'COUPON_NOT_APPLICABLE' using errcode = 'P0001';
    end if;
  end if;

  v_total := round(coalesce(v_total, 0), 2);

  if v_c.type = 'valor_fixo' then
    return least(greatest(round(v_c.value, 2), 0), v_total);   -- novo total, sem acréscimo
  elsif v_c.type = 'percentual' then
    return round(v_total * (1 - v_c.value / 100.0), 2);
  else
    raise exception 'COUPON_INVALID' using errcode = 'P0001';
  end if;
end;
$$;

revoke execute on function public._apply_coupon(text, bigint[])
  from public, anon, authenticated, service_role;

-- ══ _resolve_discount ══════════════════════════════════════════════════════
-- p_discount: {"mode":"none"} | {"mode":"coupon","code":..} |
--             {"mode":"manual","price":..} | {"mode":"pct","pct":..}
--             (+ "motivo" opcional)
-- devolve (o_valor_servico, o_desconto_abs, o_pct, o_motivo, o_coupon_code).
-- Regras:
--   - sem serviço (p_svc_total <= 0) → só 'none' é aceito; senão DISCOUNT_NOT_ALLOWED
--   - coupon: EXENTO do teto por papel e do motivo (é instrumento do admin)
--   - manual/pct: acréscimo (pct<0) → DISCOUNT_NOT_ALLOWED
--                 pct > teto(papel)  → DISCOUNT_NOT_ALLOWED
--                 pct > threshold    → motivo obrigatório senão DISCOUNT_MOTIVO_REQUIRED
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
         from jsonb_array_elements_text(coalesce(p_discount -> 'service_ids', '[]'::jsonb)) e));
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
    v_price := round((p_discount ->> 'price')::numeric, 2);
    o_desconto_abs := round(v_svc - v_price, 2);
    o_pct := round(o_desconto_abs / v_svc * 100, 4);
  elsif v_mode = 'pct' then
    o_pct := round((p_discount ->> 'pct')::numeric, 4);
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

-- ══ _lock_checkout ═════════════════════════════════════════════════════════
-- reivindicação ATÔMICA da idempotency_key: advisory xact lock 'checkout|<key>'
-- ANTES de qualquer leitura/escrita do log (proposta §4.5). Padrão _lock_agenda.
create or replace function public._lock_checkout(p_idempotency_key uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('checkout|' || p_idempotency_key::text, 0));
end;
$$;

revoke execute on function public._lock_checkout(uuid)
  from public, anon, authenticated, service_role;

-- ══ _staff_insert_completed_walkin_appt ════════════════════════════════════
-- atendimento CONCLUÍDO de balcão com conta (proposta §4.3-bis). NÃO usa o
-- núcleo genérico `_staff_insert_appointment` (que rejeita `concluido`). Data/
-- hora sempre do servidor no fuso da loja. SEM regra de marcação (grade,
-- janela, _barber_covers, sobreposição) — é registro do que ocorreu. Roda
-- dentro da transação de `staff_checkout` → rollback junto com a venda.
create or replace function public._staff_insert_completed_walkin_appt(
  p_barber_id     uuid,
  p_client_id     uuid,
  p_client_name   text,
  p_client_email  text,
  p_service_names text[],
  p_duration      int,
  p_notes         text
)
returns bigint
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_cfg       public.shop_settings%rowtype;
  v_now       timestamp;
  v_day       date;
  v_dow       int;
  v_day_label text;
  v_id        bigint;
begin
  if p_client_id is null then
    raise exception 'CLIENT_INVALID' using errcode = 'P0001';
  end if;
  if p_service_names is null or cardinality(p_service_names) = 0 then
    raise exception 'SERVICE_INVALID' using errcode = 'P0001';
  end if;
  if p_duration is null or p_duration <= 0 then
    raise exception 'BAD_DURATION' using errcode = 'P0001';
  end if;
  if not exists (
    select 1 from public.barbers b where b.id = p_barber_id and b.is_barber = true
  ) then
    raise exception 'BARBER_OFF' using errcode = 'P0001';
  end if;

  select * into v_cfg from public.shop_settings where id = 1;
  v_now := now() at time zone v_cfg.timezone;
  v_day := v_now::date;
  v_dow := extract(dow from v_day)::int;
  v_day_label := (array['Dom','Seg','Ter','Qua','Qui','Sex','Sáb'])[v_dow + 1]
                 || ' ' || to_char(v_day, 'DD/MM');

  insert into public.appointments
    (client_id, barber_id, services, day, day_label, time, duration,
     status, is_encaixe, iniciado_em, client_name, client_email, notes)
  values
    (p_client_id, p_barber_id, p_service_names, v_day, v_day_label,
     to_char(v_now, 'HH24:MI'), p_duration,
     'concluido', false, now(), p_client_name, p_client_email, p_notes)
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public._staff_insert_completed_walkin_appt(
  uuid, uuid, text, text, text[], int, text
) from public, anon, authenticated, service_role;

-- ══ decrement_product_stock — REESCRITO (D-ST2-10 estratégia única) ═════════
create or replace function public.decrement_product_stock(p_id bigint, p_qty integer)
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_new int;
begin
  if public.barber_role() is null then
    raise exception 'NOT_STAFF' using errcode = 'P0001';   -- anon / cliente
  end if;
  if p_qty is null or p_qty <= 0 then
    raise exception 'BAD_QTY' using errcode = 'P0001';
  end if;

  update public.products set stock = stock - p_qty
    where id = p_id and stock >= p_qty
    returning stock into v_new;

  if v_new is null then
    raise exception 'OUT_OF_STOCK' using errcode = 'P0001';
  end if;
  return v_new;
end;
$$;

-- revoke anon (não usava); MANTÉM authenticated → o `#barberApp` legado (staff
-- logado) segue chamando. Versão owner-only entra só no cutover.
revoke execute on function public.decrement_product_stock(bigint, integer)
  from public, anon, service_role;
grant execute on function public.decrement_product_stock(bigint, integer) to authenticated;

-- ══ validate_coupon — revoke anon ══════════════════════════════════════════
revoke execute on function public.validate_coupon(text) from anon;
-- (grant a `authenticated` permanece — o wizard do cliente logado usa)
