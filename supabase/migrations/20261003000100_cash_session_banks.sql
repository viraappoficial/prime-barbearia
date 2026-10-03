-- Caixa por sessão — lista de contas bancárias para o destino de sangria/fechamento.
-- bank_accounts só é legível por admin (RLS), mas a pessoa de vendas precisa escolher a
-- conta quando o excedente do fechamento vai pro banco. Esta função devolve SÓ id e
-- nome (nunca agência/conta/número) e só pra admin e vendas.
--
-- Rollback:
--   drop function public.cash_session_bank_accounts();
-- Impacto: nenhum no legado; função nova.

create or replace function public.cash_session_bank_accounts()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_role text := public._cs_role(auth.uid());
begin
  if v_uid is null or v_role is null or v_role not in ('admin', 'vendas') then
    raise exception 'NOT_ALLOWED' using errcode = 'P0001';
  end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name) order by a.name), '[]'::jsonb)
    from public.bank_accounts a
  );
end;
$$;

revoke execute on function public.cash_session_bank_accounts() from public, anon, authenticated, service_role;
grant execute on function public.cash_session_bank_accounts() to authenticated;
