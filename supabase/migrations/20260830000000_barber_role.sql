-- ST-H.1 — helper de papel de staff: `public.barber_role()`.
--
-- Hoje cada policy de gestão inlina
--   EXISTS (select 1 from barbers where id = auth.uid() and role = '<papel>')
-- Isso repete lógica, custa um subselect correlacionado por linha e é fácil
-- divergir entre policies. Este helper centraliza: devolve o papel do PRÓPRIO
-- `auth.uid()` ('admin' | 'barbeiro' | 'vendas') ou null (não é staff).
--
-- SECURITY DEFINER + `search_path = ''` + objeto qualificado. Owner = postgres
-- (rolbypassrls) → lê `public.barbers` sem a RLS da tabela atrapalhar, e
-- funciona também para requests `anon` (auth.uid() = null → 0 linhas → null).
-- NUNCA vaza o papel de outro usuário: filtra por `id = auth.uid()`.
--
-- EXECUTE = anon + authenticated (NÃO só authenticated). As policies que a
-- ST-H.2 reescreve são `TO public` e são avaliadas TAMBÉM para requests `anon`
-- (o `anon` ainda tem SELECT em `public.appointments` no baseline). Sem EXECUTE
-- para `anon`, a policy erraria `permission denied for function public.barber_role`
-- em vez de simplesmente retornar 0 linhas.
--
-- Sozinha, esta migration é INERTE: só adiciona a função, não recria policy
-- nenhuma (isso é a ST-H.2). O gate 1 aplica ST-H.1–5 juntas no lab.
--
-- Rollback:
--   drop function public.barber_role();
--   (só depois de reverter a ST-H.2 / ST-H.3, que passam a depender dela)
-- Impacto no legado: nenhum. Função nova, ninguém chama até a ST-H.2.

create or replace function public.barber_role()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select role from public.barbers where id = auth.uid()
$$;

-- os default privileges do Supabase concedem EXECUTE a anon/authenticated/
-- service_role em toda função nova de `public`; normalizar explicitamente para
-- o conjunto mínimo (anon + authenticated). postgres/supabase_admin mantêm
-- EXECUTE implícito (super/owner).
revoke execute on function public.barber_role()
  from public, anon, authenticated, service_role;
grant execute on function public.barber_role() to anon, authenticated;
