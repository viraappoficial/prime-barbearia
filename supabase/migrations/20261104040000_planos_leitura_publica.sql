-- Os planos ativos (nome, preço e o que inclui) são informação de vitrine: o visitante sem conta também vê. Comprar continua exigindo login.
drop policy if exists planos_public_read on public.planos;
create policy planos_public_read on public.planos for select to anon using (ativo);
drop policy if exists plano_itens_public_read on public.plano_itens;
create policy plano_itens_public_read on public.plano_itens for select to anon
  using (exists (select 1 from public.planos p where p.id = plano_id and p.ativo));
grant select on public.planos, public.plano_itens to anon;
