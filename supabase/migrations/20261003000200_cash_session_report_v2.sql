-- Caixa por sessão — relatório COMPLETO de vendas no fechamento.
-- Mantém todas as chaves da versão anterior de cash_session_report (a tela antiga segue
-- funcionando) e ACRESCENTA:
--   vendas              uma por nota: cliente, itens (serviço/produto, qtd, valor, barbeiro),
--                       pagamentos (forma, valor, parcelas, bandeira, NSU, operador);
--                       late=true quando a venda foi registrada ANTES de o caixa abrir
--                       (ex.: fatura a prazo quitada hoje) — entra como recebimento, não como venda
--   totais              serviços x produtos, quantidade de vendas, total vendido (só vendas do turno)
--   por_barbeiro_vendas serviços, produtos e total por barbeiro (só vendas do turno)
--   produtos            produtos vendidos no turno (nome, quantidade, total)
--   cartoes             conciliação: forma/bandeira, quantidade e total (débito, crédito, pix maquininha)
--
-- "Vendas do turno" = notas com pagamento nesta sessão E itens registrados desde a abertura do caixa.
-- Sem mudança de schema, permissões nem grants (create or replace mantém os existentes).
--
-- Rollback: reaplicar o corpo de cash_session_report da migration 20261003000000_cash_sessions.sql
-- Impacto: nenhum no legado; só devolve mais campos.

create or replace function public.cash_session_report(p_session bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  s        public.cash_sessions%rowtype;
  v_vendas jsonb;
  v_tot    jsonb;
  v_barb   jsonb;
  v_prod   jsonb;
  v_cart   jsonb;
begin
  if v_uid is null or public._cs_role(v_uid) is null then
    raise exception 'NOT_STAFF' using errcode = 'P0001';
  end if;
  select * into s from public.cash_sessions where id = p_session;
  if not found then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
  if public._cs_role(v_uid) <> 'admin' and s.opened_by <> v_uid then
    raise exception 'NOT_ALLOWED' using errcode = 'P0001';
  end if;

  -- uma entrada por nota paga nesta sessão
  select coalesce(jsonb_agg(jsonb_build_object(
           'nota_id', n.nota_id, 'at', n.first_pay, 'sold_at', n.sold_at,
           'late', coalesce(n.sold_at < s.opened_at, false),
           'client', n.client, 'items_total', n.items_total, 'paid', n.paid,
           'items', n.items, 'payments', n.pays) order by n.first_pay, n.nota_id), '[]'::jsonb)
  into v_vendas
  from (
    select p0.nota_id,
           min(p0.created_at) as first_pay,
           sum(p0.value) as paid,
           (select min(sl.created_at) from public.sales sl where sl.nota_id = p0.nota_id) as sold_at,
           (select min(sl.client_name) from public.sales sl where sl.nota_id = p0.nota_id) as client,
           (select coalesce(sum(sl.value), 0) from public.sales sl where sl.nota_id = p0.nota_id) as items_total,
           (select coalesce(jsonb_agg(jsonb_build_object(
                     'service', sl.service, 'qty', coalesce(sl.qty, 1), 'value', sl.value,
                     'tipo', coalesce(sl.type, 'servico'), 'category', sl.category,
                     'barber_id', sl.barber_id,
                     'barber', (select b.name from public.barbers b where b.id = sl.barber_id))
                   order by sl.id), '[]'::jsonb)
            from public.sales sl where sl.nota_id = p0.nota_id) as items,
           (select coalesce(jsonb_agg(jsonb_build_object(
                     'method', p.method, 'value', p.value, 'parcelas', p.parcelas,
                     'bandeira', p.bandeira, 'nsu', p.nsu, 'at', p.created_at,
                     'operator', (select b.name from public.barbers b where b.id = p.operator_id))
                   order by p.id), '[]'::jsonb)
            from public.sale_payments p
            where p.cash_session_id = s.id and p.nota_id = p0.nota_id) as pays
    from public.sale_payments p0
    where p0.cash_session_id = s.id
    group by p0.nota_id
  ) n;

  -- totais do turno: serviços x produtos (só o que foi vendido desde a abertura)
  select jsonb_build_object(
           'servicos',     coalesce(sum(case when t.tipo <> 'produto' then t.value end), 0),
           'produtos',     coalesce(sum(case when t.tipo = 'produto' then t.value end), 0),
           'qtd_servicos', coalesce(sum(case when t.tipo <> 'produto' then 1 end), 0),
           'qtd_produtos', coalesce(sum(case when t.tipo = 'produto' then t.qty end), 0),
           'qtd_vendas',   count(distinct t.nota_id),
           'total',        coalesce(sum(t.value), 0))
  into v_tot
  from (
    select sl.nota_id, sl.value, coalesce(sl.qty, 1) as qty, coalesce(sl.type, 'servico') as tipo
    from public.sales sl
    where sl.created_at >= s.opened_at
      and sl.nota_id in (select p.nota_id from public.sale_payments p where p.cash_session_id = s.id)
  ) t;

  select coalesce(jsonb_agg(jsonb_build_object(
           'barber_id', x.barber_id, 'name', b.name,
           'servicos', x.servicos, 'produtos', x.produtos, 'total', x.total) order by x.total desc), '[]'::jsonb)
  into v_barb
  from (
    select sl.barber_id,
           sum(case when coalesce(sl.type, 'servico') <> 'produto' then sl.value else 0 end) as servicos,
           sum(case when sl.type = 'produto' then sl.value else 0 end) as produtos,
           sum(sl.value) as total
    from public.sales sl
    where sl.created_at >= s.opened_at
      and sl.nota_id in (select p.nota_id from public.sale_payments p where p.cash_session_id = s.id)
    group by sl.barber_id
  ) x
  left join public.barbers b on b.id = x.barber_id;

  select coalesce(jsonb_agg(jsonb_build_object('name', x.service, 'qty', x.qty, 'total', x.total)
                            order by x.total desc), '[]'::jsonb)
  into v_prod
  from (
    select sl.service, sum(coalesce(sl.qty, 1)) as qty, sum(sl.value) as total
    from public.sales sl
    where sl.type = 'produto'
      and sl.created_at >= s.opened_at
      and sl.nota_id in (select p.nota_id from public.sale_payments p where p.cash_session_id = s.id)
    group by sl.service
  ) x;

  select coalesce(jsonb_agg(jsonb_build_object(
           'method', x.method, 'bandeira', x.bandeira, 'qtd', x.qtd, 'total', x.total)
           order by x.method, x.bandeira), '[]'::jsonb)
  into v_cart
  from (
    select p.method, coalesce(p.bandeira, '') as bandeira, count(*) as qtd, sum(p.value) as total
    from public.sale_payments p
    where p.cash_session_id = s.id and p.method in ('debito', 'credito', 'pix_qrs')
    group by p.method, coalesce(p.bandeira, '')
  ) x;

  return jsonb_build_object(
    'session', to_jsonb(s) || jsonb_build_object(
        'opened_by_name', (select b.name from public.barbers b where b.id = s.opened_by),
        'opened_confirmed_by_name', (select b.name from public.barbers b where b.id = s.opened_confirmed_by),
        'closed_by_name', (select b.name from public.barbers b where b.id = s.closed_by),
        'closed_confirmed_by_name', (select b.name from public.barbers b where b.id = s.closed_confirmed_by)),
    'expected_cash', case when s.closed_at is null then public._cs_expected(s.id) else s.expected_cash end,
    'by_method', (
      select coalesce(jsonb_object_agg(m.method, m.total), '{}'::jsonb)
      from (select p.method, sum(p.value) as total
            from public.sale_payments p where p.cash_session_id = s.id group by p.method) m),
    'by_barber', (
      select coalesce(jsonb_agg(jsonb_build_object('barber_id', x.barber_id, 'name', b.name, 'total', x.total)
                                order by x.total desc), '[]'::jsonb)
      from (select p.barber_id, sum(p.value) as total
            from public.sale_payments p
            where p.cash_session_id = s.id and p.method <> 'a_prazo' group by p.barber_id) x
      left join public.barbers b on b.id = x.barber_id),
    'by_operator', (
      select coalesce(jsonb_agg(jsonb_build_object('operator_id', x.operator_id, 'name', b.name, 'total', x.total)
                                order by x.total desc), '[]'::jsonb)
      from (select p.operator_id, sum(p.value) as total
            from public.sale_payments p
            where p.cash_session_id = s.id and p.method <> 'a_prazo' group by p.operator_id) x
      left join public.barbers b on b.id = x.operator_id),
    'sangrias', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', g.id, 'value', g.value, 'destino', g.destino, 'note', g.note,
               'is_closing', g.is_closing, 'operator_id', g.operator_id, 'created_at', g.created_at)
             order by g.created_at), '[]'::jsonb)
      from public.cash_sangrias g where g.cash_session_id = s.id),
    'suprimentos', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', u.id, 'value', u.value, 'origem', u.origem, 'note', u.note,
               'operator_id', u.operator_id, 'created_at', u.created_at)
             order by u.created_at), '[]'::jsonb)
      from public.cash_supplies u where u.cash_session_id = s.id),
    'notas', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'nota_id', n.nota_id, 'at', n.at, 'paid', n.paid, 'methods', n.methods,
               'client', (select min(sl.client_name) from public.sales sl where sl.nota_id = n.nota_id),
               'items', (select string_agg(sl.service || case when coalesce(sl.qty, 1) > 1 then ' x' || sl.qty else '' end,
                                           ' + ' order by sl.id)
                         from public.sales sl where sl.nota_id = n.nota_id))
             order by n.at), '[]'::jsonb)
      from (select p.nota_id, min(p.created_at) as at, sum(p.value) as paid,
                   string_agg(distinct p.method, ', ') as methods
            from public.sale_payments p where p.cash_session_id = s.id group by p.nota_id) n),
    'vendas', v_vendas,
    'totais', v_tot,
    'por_barbeiro_vendas', v_barb,
    'produtos', v_prod,
    'cartoes', v_cart
  );
end;
$$;
