-- Estorno de venda no Caixa.
--
-- O que faz: o admin (com a senha dele, como em sangria/fechamento) estorna uma venda inteira do caixa ABERTO.
--   • A venda estornada SAI de sales e sale_payments — então some sozinha de todos os relatórios, do dinheiro esperado
--     do caixa (a parte em dinheiro sai da conta, que é o que acontece de verdade na gaveta), da comissão e do painel.
--   • Fica um registro permanente em sale_reversals: quem estornou, quem aprovou, quando, o motivo e uma cópia de tudo
--     (itens e pagamentos), pra aparecer no relatório do caixa e poder ser auditado.
--   • Produto volta pro estoque (procura o produto pelo nome; se o nome não bater com um produto só, não mexe e avisa no registro).
--   • Atendimento concluído ligado à venda vira "cancelado" (deixa de contar no histórico e na fidelidade).
--   • Venda a prazo (fiado) ainda em aberto é cancelada junto; se o fiado já foi pago, o estorno é recusado (FIADO_PAGO).
--   • Só estorna venda do caixa aberto (NOT_FOUND se a venda não tem pagamento nele). Não existe estorno de caixa fechado.
--   • Como o número da nota (nota_id) vem de um contador de cada navegador, as vendas da nota só são consideradas
--     até 15 min em volta do primeiro pagamento — assim uma nota com o mesmo número em outro dia nunca é pega por engano.
--
-- Erros (P0001): NOT_ADMIN, NO_OPEN_SESSION, BAD_OPERATOR, NOT_SESSION_OWNER, BAD_REASON, NOT_FOUND, FIADO_PAGO.
-- O relatório do caixa (cash_session_report) passa a trazer 'estornos', 'estornos_total' e 'estornos_dinheiro'.
--
-- Rollback (nesta ordem):
--   drop function public.sale_reverse(uuid, bigint, text, text);
--   reaplicar cash_session_report da migration 20261009000000_cash_session_report_item_dates.sql;
--   drop table public.sale_reversals;
--   (vendas já estornadas NÃO voltam: a cópia delas fica em sale_reversals.items/payments antes de dropar a tabela)
-- Impacto: tabela nova + função nova + relatório com 3 chaves a mais. Não altera coluna, policy nem dado existente.

create table public.sale_reversals (
  id               bigint generated always as identity primary key,
  nota_id          bigint not null,
  cash_session_id  bigint not null references public.cash_sessions(id),
  client_name      text,
  total            numeric not null,
  cash_value       numeric not null default 0,
  reason           text not null check (char_length(btrim(reason)) between 1 and 80),
  note             text check (char_length(note) <= 300),
  items            jsonb not null default '[]'::jsonb,
  payments         jsonb not null default '[]'::jsonb,
  restocked        jsonb not null default '[]'::jsonb,
  reversed_by      uuid not null references public.barbers(id),
  approved_by      uuid not null references public.barbers(id),
  created_at       timestamptz not null default now()
);
create index sale_reversals_session_idx on public.sale_reversals (cash_session_id);
create index sale_reversals_nota_idx on public.sale_reversals (nota_id);

alter table public.sale_reversals enable row level security;
revoke all on public.sale_reversals from public, anon, authenticated;
grant select on public.sale_reversals to authenticated;
-- só admin e vendas leem; ninguém grava direto (só a função abaixo)
create policy sale_reversals_staff_select on public.sale_reversals
  for select to authenticated
  using (exists (select 1 from public.barbers b where b.id = auth.uid() and b.role in ('admin', 'vendas')));

create or replace function public.sale_reverse(
  p_operator uuid, p_nota_id bigint, p_reason text, p_note text default null
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin   uuid;
  s         public.cash_sessions%rowtype;
  v_first   timestamptz;
  v_pay     jsonb;
  v_cash    numeric;
  v_total   numeric;
  v_sale_ids bigint[];
  v_items   jsonb;
  v_client  text;
  v_restock jsonb := '[]'::jsonb;
  v_id      bigint;
  r         record;
  v_n       integer;
  v_pid     bigint;
begin
  v_admin := public._cs_require_admin();
  select * into s from public.cash_sessions where closed_at is null for share;
  if not found then
    raise exception 'NO_OPEN_SESSION' using errcode = 'P0001';
  end if;
  perform public._cs_check_operator(p_operator, s.opened_by);
  if p_reason is null or btrim(p_reason) = '' or char_length(btrim(p_reason)) > 80 then
    raise exception 'BAD_REASON' using errcode = 'P0001';
  end if;

  -- pagamentos da nota neste caixa
  select min(p.created_at),
         coalesce(jsonb_agg(jsonb_build_object('method', p.method, 'value', p.value, 'parcelas', p.parcelas,
                  'bandeira', p.bandeira, 'nsu', p.nsu) order by p.id), '[]'::jsonb),
         coalesce(sum(p.value) filter (where p.method = 'dinheiro'), 0),
         coalesce(sum(p.value), 0)
  into v_first, v_pay, v_cash, v_total
  from public.sale_payments p
  where p.nota_id = p_nota_id and p.cash_session_id = s.id;
  if v_first is null then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;

  -- itens vendidos da nota (janela de 15 min em volta do 1º pagamento: ver cabeçalho)
  select array_agg(sl.id order by sl.id),
         coalesce(jsonb_agg(jsonb_build_object('service', sl.service, 'qty', coalesce(sl.qty, 1), 'value', sl.value,
                  'tipo', coalesce(sl.type, 'servico'), 'category', sl.category, 'barber_id', sl.barber_id,
                  'appointment_id', sl.appointment_id) order by sl.id), '[]'::jsonb),
         min(sl.client_name)
  into v_sale_ids, v_items, v_client
  from public.sales sl
  where sl.nota_id = p_nota_id
    and sl.created_at between v_first - interval '15 minutes' and v_first + interval '15 minutes';

  -- fiado já pago não se desfaz por aqui
  if exists (select 1 from public.fiado_charges f where f.nota_id = p_nota_id and f.status <> 'aberto') then
    raise exception 'FIADO_PAGO' using errcode = 'P0001';
  end if;

  -- produtos voltam pro estoque (só quando o nome identifica um produto único)
  for r in
    select sl.service, coalesce(sl.qty, 1) as qty
    from public.sales sl
    where sl.id = any(coalesce(v_sale_ids, '{}')) and sl.type = 'produto'
  loop
    select count(*), min(pr.id) into v_n, v_pid from public.products pr where lower(pr.name) = lower(r.service);
    if v_n = 1 then
      update public.products set stock = stock + r.qty where id = v_pid;
      v_restock := v_restock || jsonb_build_object('product', r.service, 'qty', r.qty, 'restocked', true);
    else
      v_restock := v_restock || jsonb_build_object('product', r.service, 'qty', r.qty, 'restocked', false);
    end if;
  end loop;

  -- atendimento concluído ligado à venda deixa de contar
  update public.appointments set status = 'cancelado'
  where status = 'concluido'
    and id in (select sl.appointment_id from public.sales sl
               where sl.id = any(coalesce(v_sale_ids, '{}')) and sl.appointment_id is not null);

  delete from public.fiado_charges where nota_id = p_nota_id and status = 'aberto';

  insert into public.sale_reversals
    (nota_id, cash_session_id, client_name, total, cash_value, reason, note, items, payments, restocked, reversed_by, approved_by)
  values (p_nota_id, s.id, v_client, v_total, v_cash, btrim(p_reason), nullif(btrim(coalesce(p_note, '')), ''),
          v_items, v_pay, v_restock, p_operator, v_admin)
  returning id into v_id;

  delete from public.sale_payments where nota_id = p_nota_id and cash_session_id = s.id;
  delete from public.sales where id = any(coalesce(v_sale_ids, '{}'));
  return v_id;
end;
$$;

revoke all on function public.sale_reverse(uuid, bigint, text, text) from public, anon;
grant execute on function public.sale_reverse(uuid, bigint, text, text) to authenticated;

-- ══ relatório do caixa com os estornos ══
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
  v_est    jsonb;
begin
  if v_uid is null or public._cs_role(v_uid) is null then
    raise exception 'NOT_STAFF' using errcode = 'P0001';
  end if;
  select * into s from public.cash_sessions where id = p_session;
  if not found then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
  if public._cs_role(v_uid) not in ('admin', 'vendas') then
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
                     'tipo', coalesce(sl.type, 'servico'), 'category', sl.category, 'at', sl.created_at,
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

  -- estornos feitos neste caixa (a venda estornada some de vendas/pagamentos/totais; aqui fica o registro)
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', r.id, 'nota_id', r.nota_id, 'at', r.created_at, 'client', r.client_name,
           'total', r.total, 'cash', r.cash_value, 'reason', r.reason, 'note', r.note,
           'items', r.items, 'payments', r.payments,
           'reversed_by_name', (select b.name from public.barbers b where b.id = r.reversed_by),
           'approved_by_name', (select b.name from public.barbers b where b.id = r.approved_by))
         order by r.created_at), '[]'::jsonb)
  into v_est
  from public.sale_reversals r where r.cash_session_id = s.id;

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
    'cartoes', v_cart,
    'estornos', v_est,
    'estornos_total', (select coalesce(sum(r.total), 0) from public.sale_reversals r where r.cash_session_id = s.id),
    'estornos_dinheiro', (select coalesce(sum(r.cash_value), 0) from public.sale_reversals r where r.cash_session_id = s.id)
  );
end;
$$;
