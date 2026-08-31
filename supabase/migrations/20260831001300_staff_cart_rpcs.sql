-- ST-2.4 — RPCs do carrinho de atendimento + leitura consolidada da tela.
--
--   staff_cart_add_item     — adiciona produto ao carrinho (não decrementa estoque)
--   staff_cart_set_qty      — muda a quantidade (0 = remove)
--   staff_cart_set_services — ÚNICO escritor de appointments.services/
--                             discount_price/coupon_code/discount_motivo pelo app
--   staff_checkout_get      — leitura consolidada (appt + carrinho + catálogo +
--                             totais + teto de desconto do papel)
--
-- Todas: `security definer`, `set search_path = ''`, objetos qualificados,
-- posse/estado revalidados SOB o lock (`_staff_appt_for_write_locked`),
-- `revoke execute` de todos → `grant` só a `authenticated`. Erros P0001.
--
-- Só operam sobre atendimento EM ANDAMENTO (`status='confirmado' AND
-- iniciado_em IS NOT NULL`) — o carrinho do legado abre a partir de um
-- atendimento iniciado.
--
-- Rollback:
--   drop function public.staff_cart_add_item(bigint, bigint, int);
--   drop function public.staff_cart_set_qty(bigint, bigint, int);
--   drop function public.staff_cart_set_services(bigint, bigint[], jsonb);
--   drop function public.staff_checkout_get(bigint);
--   drop policy cart_items_admin_all on public.cart_items;
-- Impacto no legado: nenhum — `#barberApp` segue no CRUD direto de `cart_items`
-- (`cart_items_own` / `cart_items_vendas_all`).

-- ── policy de admin em cart_items (D-ST2-9) ──────────────────────────────────
-- Usa o `EXISTS (... role='admin')` inline — mesmo padrão de
-- `cart_items_vendas_all` e das policies admin de `sales`/`products`/`cash_*`.
-- Deliberadamente NÃO usa `barber_role()`: evita criar dependência dura
-- policy→função (a policy bloquearia o `drop function barber_role()` do ciclo de
-- rollback isolado da ST-H — as policies da ST-H.2 são revertidas antes do drop;
-- uma policy nova da ST-2 não é).
do $$ begin
  create policy cart_items_admin_all on public.cart_items
    as permissive for all to authenticated
    using (exists (select 1 from public.barbers b where b.id = auth.uid() and b.role = 'admin'))
    with check (exists (select 1 from public.barbers b where b.id = auth.uid() and b.role = 'admin'));
exception when duplicate_object then null; end $$;

-- ── helper: appt travado + em andamento ─────────────────────────────────────
create or replace function public._staff_cart_appt(p_appt_id bigint)
returns public.appointments
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_appt public.appointments%rowtype := public._staff_appt_for_write_locked(p_appt_id, true);
begin
  if v_appt.status <> 'confirmado' or v_appt.iniciado_em is null then
    raise exception 'BAD_STATE' using errcode = 'P0001';   -- não está em atendimento
  end if;
  return v_appt;
end;
$$;

revoke execute on function public._staff_cart_appt(bigint)
  from public, anon, authenticated, service_role;

-- ── staff_cart_add_item ────────────────────────────────────────────────────
create or replace function public.staff_cart_add_item(
  p_appt_id    bigint,
  p_product_id bigint,
  p_qty        int default 1
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_appt    public.appointments%rowtype := public._staff_cart_appt(p_appt_id);
  v_stock   int;
  v_cur     int;
  v_row_id  bigint;
begin
  if p_qty is null or p_qty <= 0 then
    raise exception 'BAD_QTY' using errcode = 'P0001';
  end if;

  select stock into v_stock from public.products where id = p_product_id;
  if not found then
    raise exception 'PRODUCT_INVALID' using errcode = 'P0001';
  end if;

  select id, qty into v_row_id, v_cur
  from public.cart_items where appointment_id = p_appt_id and product_id = p_product_id
  for update;

  if coalesce(v_cur, 0) + p_qty > v_stock then
    raise exception 'OUT_OF_STOCK' using errcode = 'P0001';
  end if;

  if v_row_id is not null then
    update public.cart_items set qty = v_cur + p_qty where id = v_row_id;
  else
    insert into public.cart_items (appointment_id, barber_id, product_id, qty)
    values (p_appt_id, v_appt.barber_id, p_product_id, p_qty);
  end if;

  return public.staff_checkout_get(p_appt_id);
end;
$$;

revoke execute on function public.staff_cart_add_item(bigint, bigint, int)
  from public, anon, authenticated, service_role;
grant execute on function public.staff_cart_add_item(bigint, bigint, int) to authenticated;

-- ── staff_cart_set_qty ─────────────────────────────────────────────────────
create or replace function public.staff_cart_set_qty(
  p_appt_id    bigint,
  p_product_id bigint,
  p_qty        int
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_appt  public.appointments%rowtype := public._staff_cart_appt(p_appt_id);
  v_stock int;
  v_id    bigint;
begin
  if p_qty is null or p_qty < 0 then
    raise exception 'BAD_QTY' using errcode = 'P0001';
  end if;

  select id into v_id from public.cart_items
  where appointment_id = p_appt_id and product_id = p_product_id for update;

  if p_qty = 0 then
    if v_id is not null then delete from public.cart_items where id = v_id; end if;
    return public.staff_checkout_get(p_appt_id);
  end if;

  select stock into v_stock from public.products where id = p_product_id;
  if not found then
    raise exception 'PRODUCT_INVALID' using errcode = 'P0001';
  end if;
  if p_qty > v_stock then
    raise exception 'OUT_OF_STOCK' using errcode = 'P0001';
  end if;

  if v_id is not null then
    update public.cart_items set qty = p_qty where id = v_id;
  else
    insert into public.cart_items (appointment_id, barber_id, product_id, qty)
    values (p_appt_id, v_appt.barber_id, p_product_id, p_qty);
  end if;

  return public.staff_checkout_get(p_appt_id);
end;
$$;

revoke execute on function public.staff_cart_set_qty(bigint, bigint, int)
  from public, anon, authenticated, service_role;
grant execute on function public.staff_cart_set_qty(bigint, bigint, int) to authenticated;

-- ── staff_cart_set_services ────────────────────────────────────────────────
-- p_discount: {"mode":"none"} | {"mode":"coupon","code":..} |
--             {"mode":"manual","price":..} | {"mode":"pct","pct":..}  (+ "motivo")
-- Persiste appointments.{services, discount_price, coupon_code, discount_motivo}.
create or replace function public.staff_cart_set_services(
  p_appt_id     bigint,
  p_service_ids bigint[],
  p_discount    jsonb default '{"mode":"none"}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_appt   public.appointments%rowtype := public._staff_cart_appt(p_appt_id);
  v_names  text[];
  v_dur    int;
  v_total  numeric;
  v_role   text := public.barber_role();
  d        record;
  v_disc   jsonb := coalesce(p_discount, '{"mode":"none"}'::jsonb);
begin
  select o_names, o_dur, o_total into v_names, v_dur, v_total
  from public._validate_services_priced(p_service_ids);

  -- injeta service_ids no jsonb p/ o modo cupom do _resolve_discount
  if (v_disc ->> 'mode') = 'coupon' then
    v_disc := v_disc || jsonb_build_object('service_ids', to_jsonb(p_service_ids));
  end if;

  select * into d from public._resolve_discount(v_role, v_disc, v_total);

  update public.appointments set
    services       = v_names,
    discount_price = d.o_valor_servico,
    coupon_code    = d.o_coupon_code,
    discount_motivo = d.o_motivo
  where id = p_appt_id;

  return public.staff_checkout_get(p_appt_id);
end;
$$;

revoke execute on function public.staff_cart_set_services(bigint, bigint[], jsonb)
  from public, anon, authenticated, service_role;
grant execute on function public.staff_cart_set_services(bigint, bigint[], jsonb) to authenticated;

-- ── staff_checkout_get — leitura consolidada da tela ───────────────────────
create or replace function public.staff_checkout_get(p_appt_id bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_appt   public.appointments%rowtype;
  v_uid    uuid := auth.uid();
  v_role   text;
  v_cfg    public.shop_settings%rowtype;
  v_svc_tabela numeric := 0;
  v_produtos   numeric := 0;
  v_cap    numeric;
  v_cart   jsonb;
  v_svc    jsonb;
begin
  if v_uid is null then raise exception 'NOT_AUTH' using errcode = 'P0001'; end if;
  v_role := public.barber_role();
  if v_role is null then raise exception 'NOT_STAFF' using errcode = 'P0001'; end if;

  select * into v_appt from public.appointments where id = p_appt_id;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if not (v_appt.barber_id = v_uid or v_role in ('admin','vendas')) then
    raise exception 'NOT_FOUND' using errcode = 'P0001';   -- não vaza posse
  end if;

  select * into v_cfg from public.shop_settings where id = 1;
  v_cap := case v_role
             when 'barbeiro' then v_cfg.max_discount_barbeiro
             when 'vendas'   then v_cfg.max_discount_vendas
             when 'admin'    then v_cfg.max_discount_admin
             else 0 end;

  select coalesce(sum(s.price), 0) into v_svc_tabela
  from public.services s where s.name = any(coalesce(v_appt.services, '{}'::text[]));

  select
    coalesce(jsonb_agg(jsonb_build_object(
      'product_id', p.id, 'name', p.name, 'price', p.price, 'qty', ci.qty,
      'subtotal', round(p.price * ci.qty, 2), 'stock', p.stock,
      'category', coalesce(p.category, 'Outros')
    ) order by ci.id), '[]'::jsonb),
    coalesce(sum(p.price * ci.qty), 0)
  into v_cart, v_produtos
  from public.cart_items ci join public.products p on p.id = ci.product_id
  where ci.appointment_id = p_appt_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', s.id, 'name', s.name, 'price', s.price, 'category', s.category
  ) order by s.display_order, s.id), '[]'::jsonb)
  into v_svc
  from public.services s where s.active = true;

  return jsonb_build_object(
    'appt', jsonb_build_object(
      'id', v_appt.id, 'client_id', v_appt.client_id, 'client_name', v_appt.client_name,
      'barber_id', v_appt.barber_id, 'services', to_jsonb(coalesce(v_appt.services,'{}'::text[])),
      'discount_price', v_appt.discount_price, 'coupon_code', v_appt.coupon_code,
      'discount_motivo', v_appt.discount_motivo, 'status', v_appt.status,
      'iniciado_em', v_appt.iniciado_em, 'notes', v_appt.notes,
      'day', v_appt.day, 'time', v_appt.time
    ),
    'servico_tabela', round(v_svc_tabela, 2),
    'servico_liquido', round(coalesce(v_appt.discount_price, v_svc_tabela), 2),
    'produtos_total', round(v_produtos, 2),
    'total', round(coalesce(v_appt.discount_price, v_svc_tabela) + v_produtos, 2),
    'cart', v_cart,
    'servicos_catalogo', v_svc,
    'papel', v_role,
    'desconto_teto_pct', v_cap,
    'desconto_motivo_threshold', v_cfg.discount_motivo_threshold
  );
end;
$$;

revoke execute on function public.staff_checkout_get(bigint)
  from public, anon, authenticated, service_role;
grant execute on function public.staff_checkout_get(bigint) to authenticated;
