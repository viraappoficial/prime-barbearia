-- appointments: admin pode CRIAR agendamento (encaixe) em nome de qualquer barbeiro.
-- Hoje o INSERT só é aceito por 3 caminhos: vendas (appointments_vendas_insert), o próprio
-- barbeiro (barber_id = auth.uid()) e o cliente (client_id = auth.uid()). Admin só tinha
-- SELECT e UPDATE (admin_select_all / admin_update_all); então um admin que não é o barbeiro
-- do encaixe levava 42501 "new row violates row-level security policy".
-- Mesmo poder que o admin já tem no UPDATE; não afeta barbeiro, cliente nem vendas.
--
-- Rollback: drop policy appointments_admin_insert on public.appointments;
-- Impacto: só libera INSERT para role = 'admin'; idempotente.

drop policy if exists appointments_admin_insert on public.appointments;
create policy appointments_admin_insert on public.appointments
  for insert
  to authenticated
  with check (exists (select 1 from public.barbers b where b.id = auth.uid() and b.role = 'admin'));
