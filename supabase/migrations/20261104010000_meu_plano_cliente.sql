-- Plano ativo do cliente logado, para o cartão "Meu plano" do site. Procura pelo telefone do cadastro
-- (os planos migrados do balcão não têm client_id). Só devolve o plano de quem está logado; nunca recebe telefone de fora.
create or replace function public.meu_plano() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare a public.assinaturas%rowtype; fone text;
begin
  if auth.uid() is null then return null; end if;
  select public._fone_canon(c.phone) into fone from public.clients c where c.id = auth.uid();
  if fone is null or length(fone) < 10 then return null; end if;
  select * into a from public.assinaturas x
   where x.client_phone = fone and x.status = 'ativa' and public._hoje_sp() between x.inicio and x.fim
   order by x.id desc limit 1;
  if not found then return null; end if;
  return jsonb_build_object('plano', a.plano_nome, 'inicio', a.inicio, 'fim', a.fim, 'pago', a.pago_em is not null,
    'itens', (select coalesce(jsonb_agg(jsonb_build_object('item', s.item, 'total', s.total, 'restante', s.restante) order by s.item), '[]'::jsonb)
              from public.plano_saldo(a.id) s));
end $$;
revoke all on function public.meu_plano() from public, anon;
grant execute on function public.meu_plano() to authenticated;
