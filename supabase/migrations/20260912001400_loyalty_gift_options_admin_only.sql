-- ST-5 (hardening pontual, achado da investigação `17-staff-st5-gestao.md`
-- §0) — `loyalty_gift_options` (cadastro de brindes) tinha INSERT/UPDATE/
-- DELETE liberado pra QUALQUER staff logado (`EXISTS(barbers)`, sem checar
-- papel), mesma classe de furo já catalogada em `04-staff-area.md` §7.2
-- (`clients_readable_by_barbers`, `notifications_insert_staff`) — mesmo a
-- tela sendo admin-only no legado (só client-side, `baGestaoTab`).
--
-- Confirmado no legado (`index.html`): as 3 escritas
-- (`select`/`insert`/`delete` em `loyalty_gift_options`, ~L6140-6162) só
-- são exercitadas dentro da tela de Gestão (admin-only). Não existe
-- nenhuma chamada de UPDATE em lugar nenhum do legado — a policy de UPDATE
-- é órfã, mas ainda assim endurecida (mesma correção, evita herdar o
-- padrão fraco se algum dia alguém adicionar reordenação).
--
-- SELECT continua público (`USING (true)`) — o cliente também lê as
-- opções (`index.html` ~L2363, mostra ao escolher o brinde).
--
-- Fix: as 3 policies passam a checar `role = 'admin'`, mesmo padrão já
-- usado em `expenses`/`suppliers`/`chart_of_accounts`/etc (tabelas de
-- Gestão corretas).
--
-- Rollback:
--   drop policy loyalty_gift_options_barber_write on public.loyalty_gift_options;
--   drop policy loyalty_gift_options_barber_update on public.loyalty_gift_options;
--   drop policy loyalty_gift_options_barber_delete on public.loyalty_gift_options;
--   create policy loyalty_gift_options_barber_write on public.loyalty_gift_options
--     for insert to authenticated with check (exists (select 1 from barbers where barbers.id = auth.uid()));
--   create policy loyalty_gift_options_barber_update on public.loyalty_gift_options
--     for update using (exists (select 1 from barbers where barbers.id = auth.uid()));
--   create policy loyalty_gift_options_barber_delete on public.loyalty_gift_options
--     for delete using (exists (select 1 from barbers where barbers.id = auth.uid()));
-- Impacto no legado: nenhum (as 3 escritas só rodam na tela admin-only;
-- confirmado nenhuma chamada de vendas/barbeiro no código real).

drop policy if exists loyalty_gift_options_barber_write on public.loyalty_gift_options;
create policy loyalty_gift_options_barber_write on public.loyalty_gift_options
  for insert to authenticated
  with check (exists (select 1 from public.barbers where barbers.id = auth.uid() and barbers.role = 'admin'));

drop policy if exists loyalty_gift_options_barber_update on public.loyalty_gift_options;
create policy loyalty_gift_options_barber_update on public.loyalty_gift_options
  for update
  using (exists (select 1 from public.barbers where barbers.id = auth.uid() and barbers.role = 'admin'))
  with check (exists (select 1 from public.barbers where barbers.id = auth.uid() and barbers.role = 'admin'));

drop policy if exists loyalty_gift_options_barber_delete on public.loyalty_gift_options;
create policy loyalty_gift_options_barber_delete on public.loyalty_gift_options
  for delete
  using (exists (select 1 from public.barbers where barbers.id = auth.uid() and barbers.role = 'admin'));
