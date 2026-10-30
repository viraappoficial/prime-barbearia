-- Resumo do agendamento de uma cobrança, para o modal de agradecimento que o cliente vê ao voltar do pagamento.
-- O uuid da cobrança é o segredo (o mesmo critério de pix_payment_status); não expõe CPF nem dados de outros clientes.
create or replace function public.pix_payment_resumo(p_payment_id uuid)
returns table (status text, amount numeric, services text[], day_label text, "time" text, barber_name text, client_name text)
language sql stable security definer set search_path = public as $$
  select p.status, p.amount, a.services, a.day_label, a.time, b.name, a.client_name
  from appointment_payments p
  join appointments a on a.id = p.appointment_id
  left join barbers b on b.id = a.barber_id
  where p.id = p_payment_id;
$$;
revoke all on function public.pix_payment_resumo(uuid) from public;
grant execute on function public.pix_payment_resumo(uuid) to anon, authenticated, service_role;
