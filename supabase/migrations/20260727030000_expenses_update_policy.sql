-- expenses nunca precisou de UPDATE (só criava/apagava despesa). Agora que
-- Contas a Pagar precisa editar o status na baixa ("marcar como pago"),
-- falta essa policy — sem ela o Supabase só retorna 0 linhas, sem erro.
create policy expenses_admin_update on public.expenses for update
  using (exists (select 1 from barbers b where b.id = auth.uid() and b.role = 'admin'))
  with check (exists (select 1 from barbers b where b.id = auth.uid() and b.role = 'admin'));
