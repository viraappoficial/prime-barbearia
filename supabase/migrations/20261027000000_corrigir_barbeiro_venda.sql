-- Corrigir o barbeiro de uma venda lançada na conta errada (ex.: lançamento feito no login de outro barbeiro).
--  • Só admin. Não apaga nada e não mexe em valor, forma de pagamento nem caixa: troca apenas o barbeiro.
--  • Recebe os ids das linhas de `sales` (e não o nota_id, que repete entre navegadores). Os pagamentos
--    são os da mesma nota com created_at a ±15 min da venda.
--  • sales.barber_id e sale_payments.barber_id/operator_id passam ao novo barbeiro (comissão e relatório por barbeiro acompanham).
--  • Fica registrado em venda_barbeiro_correcoes (quem, quando, motivo, o que era antes).
-- Desfazer: drop function public.corrigir_barbeiro_venda(bigint[], uuid, text); drop table public.venda_barbeiro_correcoes;

create table public.venda_barbeiro_correcoes (
  id            bigint generated always as identity primary key,
  sale_ids      bigint[] not null,
  payment_ids   bigint[] not null,
  nota_ids      bigint[] not null,
  de_barbeiro   uuid[]   not null,
  para_barbeiro uuid     not null,
  motivo        text     not null,
  corrigido_por uuid     not null,
  created_at    timestamptz not null default now()
);
alter table public.venda_barbeiro_correcoes enable row level security;
revoke all on public.venda_barbeiro_correcoes from public, anon, authenticated;
grant select on public.venda_barbeiro_correcoes to authenticated;
create policy venda_barbeiro_correcoes_admin_select on public.venda_barbeiro_correcoes
  for select to authenticated
  using (exists (select 1 from public.barbers b where b.id = auth.uid() and b.role = 'admin'));

create or replace function public.corrigir_barbeiro_venda(
  p_sale_ids bigint[], p_novo_barbeiro uuid, p_motivo text default null
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_sales bigint[];
  v_pays  bigint[];
  v_notas bigint[];
  v_de    uuid[];
begin
  if v_uid is null or not exists (select 1 from public.barbers b where b.id = v_uid and b.role = 'admin') then
    raise exception 'NOT_ADMIN' using errcode = 'P0001';
  end if;
  if p_sale_ids is null or cardinality(p_sale_ids) = 0 or cardinality(p_sale_ids) > 50 then
    raise exception 'BAD_SALES' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.barbers b where b.id = p_novo_barbeiro) then
    raise exception 'BARBER_NOT_FOUND' using errcode = 'P0001';
  end if;

  select array_agg(s.id order by s.id), array_agg(distinct s.nota_id), array_agg(distinct s.barber_id)
    into v_sales, v_notas, v_de
  from public.sales s where s.id = any(p_sale_ids);
  if v_sales is null or cardinality(v_sales) <> cardinality(p_sale_ids) then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;

  select coalesce(array_agg(distinct p.id), '{}')
    into v_pays
  from public.sale_payments p
  join public.sales s on s.nota_id = p.nota_id and s.id = any(v_sales)
   and p.created_at between s.created_at - interval '15 minutes' and s.created_at + interval '15 minutes';

  update public.sales set barber_id = p_novo_barbeiro where id = any(v_sales);
  update public.sale_payments set barber_id = p_novo_barbeiro, operator_id = p_novo_barbeiro where id = any(v_pays);

  insert into public.venda_barbeiro_correcoes (sale_ids, payment_ids, nota_ids, de_barbeiro, para_barbeiro, motivo, corrigido_por)
  values (v_sales, v_pays, v_notas, v_de, p_novo_barbeiro, coalesce(nullif(btrim(p_motivo), ''), 'Barbeiro lançado errado'), v_uid);

  return cardinality(v_sales);
end;
$$;
revoke all on function public.corrigir_barbeiro_venda(bigint[], uuid, text) from public, anon;
grant execute on function public.corrigir_barbeiro_venda(bigint[], uuid, text) to authenticated;
