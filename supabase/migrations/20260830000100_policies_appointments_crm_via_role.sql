-- ST-H.2 — recria as policies de PAPEL de `appointments` e `crm_clients` usando
-- `public.barber_role()` no lugar do `EXISTS (select … from barbers …)` inline.
--
-- COMPORTAMENTO IDÊNTICO — é refactor + performance (cada policy vira 1 chamada
-- de função STABLE em vez de um subselect correlacionado por linha).
--   `barber_role() = 'admin'`  ≡  EXISTS(... role = 'admin')
--   `barber_role() = 'vendas'` ≡  EXISTS(... role = 'vendas')
-- Para `anon`: barber_role() → null → `null = 'admin'` → false (mesmo do EXISTS).
-- A matriz A/B/C/D da ST-0 (`test:staff-lab`) continua verde (SH2 / SH25).
--
-- Usa `ALTER POLICY` (não drop+create): troca só a expressão, preserva nome,
-- comando, roles e a permissividade. Sem janela sem policy.
--
-- ESCOPO (D-H1): SÓ `appointments` + `crm_clients` — as tabelas que a ST-1/ST-2
-- tocam. As demais policies de gestão (bank_accounts, expenses, sales, …)
-- migram quando cada fatia (ST-4/ST-5) chegar — menos superfície de revisão por
-- vez. `is_barber_staff()` NÃO é reescrito aqui: é usado por ~15 policies fora
-- do escopo da ST-H; muda de fluxo se o corpo mudar. Fica como está.
--
-- Policies TOCADAS (8):
--   appointments: admin_select_all, admin_update_all,
--                 appointments_vendas_insert, appointments_vendas_read,
--                 appointments_vendas_update
--   crm_clients:  crm_clients_admin_select_all,
--                 crm_clients_vendas_insert, crm_clients_vendas_read
-- Policies NÃO tocadas (não inlinam papel — usam barber_id / client_id = auth.uid()):
--   appointments: barbers_select_own, barbers_insert_own, barbers_update_own,
--                 clients_select_own, clients_insert_own, clients_update_own
--   crm_clients:  crm_clients_select_own, crm_clients_insert_own,
--                 crm_clients_update_own
--
-- Rollback (volta ao corpo inline, qualificado):
--   alter policy admin_select_all on public.appointments
--     using (exists (select 1 from public.barbers where barbers.id = auth.uid() and barbers.role = 'admin'));
--   alter policy admin_update_all on public.appointments
--     using (exists (select 1 from public.barbers where barbers.id = auth.uid() and barbers.role = 'admin'));
--   alter policy appointments_vendas_insert on public.appointments
--     with check (exists (select 1 from public.barbers where barbers.id = auth.uid() and barbers.role = 'vendas'));
--   alter policy appointments_vendas_read on public.appointments
--     using (exists (select 1 from public.barbers where barbers.id = auth.uid() and barbers.role = 'vendas'));
--   alter policy appointments_vendas_update on public.appointments
--     using (exists (select 1 from public.barbers where barbers.id = auth.uid() and barbers.role = 'vendas'));
--   alter policy crm_clients_admin_select_all on public.crm_clients
--     using (exists (select 1 from public.barbers b where b.id = auth.uid() and b.role = 'admin'));
--   alter policy crm_clients_vendas_insert on public.crm_clients
--     with check (exists (select 1 from public.barbers where barbers.id = auth.uid() and barbers.role = 'vendas'));
--   alter policy crm_clients_vendas_read on public.crm_clients
--     using (exists (select 1 from public.barbers where barbers.id = auth.uid() and barbers.role = 'vendas'));
-- Impacto no legado: nenhum comportamental — as mesmas linhas ficam visíveis /
-- graváveis para os mesmos papéis. Só o plano de execução muda.

alter policy admin_select_all on public.appointments
  using (public.barber_role() = 'admin');

alter policy admin_update_all on public.appointments
  using (public.barber_role() = 'admin');

alter policy appointments_vendas_insert on public.appointments
  with check (public.barber_role() = 'vendas');

alter policy appointments_vendas_read on public.appointments
  using (public.barber_role() = 'vendas');

alter policy appointments_vendas_update on public.appointments
  using (public.barber_role() = 'vendas');

alter policy crm_clients_admin_select_all on public.crm_clients
  using (public.barber_role() = 'admin');

alter policy crm_clients_vendas_insert on public.crm_clients
  with check (public.barber_role() = 'vendas');

alter policy crm_clients_vendas_read on public.crm_clients
  using (public.barber_role() = 'vendas');
