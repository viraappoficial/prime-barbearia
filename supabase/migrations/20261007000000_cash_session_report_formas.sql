-- Caixa por sessão — recebido por colaborador x forma de pagamento (dinheiro, cartão, pix, a prazo).
-- Função separada de cash_session_report para não reabrir a função grande já em uso.
-- Mesma regra de acesso do relatório: admin vê qualquer caixa; quem abriu vê o próprio.
--
-- "Recebido" = dinheiro + cartão (débito/crédito) + pix (maquininha/chave). A prazo aparece à parte
-- porque não é dinheiro recebido ainda. Conta o que entrou NESTE caixa, inclusive fatura a prazo
-- quitada hoje.
--
-- Rollback: drop function public.cash_session_report_formas(bigint);
-- Impacto: nenhum no legado; função nova.

create or replace function public.cash_session_report_formas(p_session bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  s     public.cash_sessions%rowtype;
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

  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'barber_id', x.barber_id, 'name', b.name,
             'dinheiro', x.dinheiro, 'cartao', x.cartao, 'pix', x.pix, 'a_prazo', x.a_prazo,
             'total', x.dinheiro + x.cartao + x.pix)
           order by (x.dinheiro + x.cartao + x.pix + x.a_prazo) desc), '[]'::jsonb)
    from (
      select p.barber_id,
             coalesce(sum(p.value) filter (where p.method = 'dinheiro'), 0) as dinheiro,
             coalesce(sum(p.value) filter (where p.method in ('debito', 'credito')), 0) as cartao,
             coalesce(sum(p.value) filter (where p.method in ('pix_qrs', 'pix_direto')), 0) as pix,
             coalesce(sum(p.value) filter (where p.method = 'a_prazo'), 0) as a_prazo
      from public.sale_payments p
      where p.cash_session_id = s.id
      group by p.barber_id
    ) x
    left join public.barbers b on b.id = x.barber_id
  );
end;
$$;

revoke execute on function public.cash_session_report_formas(bigint) from public, anon, authenticated, service_role;
grant execute on function public.cash_session_report_formas(bigint) to authenticated;
