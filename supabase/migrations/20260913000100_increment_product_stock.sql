-- ST-5.1 — revisão Codex: reposição de estoque fazia leitura + escrita
-- separadas (`select stock` no client, depois `update stock = lido+qtd`) —
-- uma venda decrementando o estoque (`decrement_product_stock`, já
-- existente, ST-2) entre as duas chamadas perdia a baixa. RPC nova, espelha
-- `decrement_product_stock` (mesmo arquivo/padrão), faz o incremento
-- ATÔMICO no banco (`update ... set stock = stock + qtd`).
--
-- Admin-only (restock é feature de Gestão — diferente do decrement, que é
-- staff geral porque roda no checkout comum).
--
-- Rollback: drop function public.increment_product_stock(bigint, integer);
-- Impacto no legado: nenhum (legado não tinha essa RPC — fazia a mesma
-- leitura+escrita não-atômica que a revisão pegou aqui; correção nova, não
-- portada do legado).

create or replace function public.increment_product_stock(p_id bigint, p_qty integer)
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_new int;
  v_role text := public.barber_role();
begin
  if v_role is distinct from 'admin' then
    raise exception 'NOT_STAFF' using errcode = 'P0001';
  end if;
  if p_qty is null or p_qty <= 0 then
    raise exception 'BAD_QTY' using errcode = 'P0001';
  end if;

  update public.products set stock = stock + p_qty
    where id = p_id
    returning stock into v_new;

  if v_new is null then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
  return v_new;
end;
$$;

revoke execute on function public.increment_product_stock(bigint, integer)
  from public, anon, service_role;
grant execute on function public.increment_product_stock(bigint, integer) to authenticated;
