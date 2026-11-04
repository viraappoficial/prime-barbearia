-- Quanto o cliente já pagou online (aprovado) por um agendamento. O barbeiro não lê appointment_payments
-- (RLS: só admin/vendas), então o carrinho/atendimento pergunta por aqui. Só devolve para quem pode
-- operar esse agendamento: admin, vendas ou o próprio barbeiro dele.
create or replace function public.pagamento_online_do_agendamento(p_appt bigint)
returns table(id uuid, amount numeric, fee numeric, provider_payment_id text)
language sql stable security definer set search_path = public as $$
  select p.id, p.amount, p.fee, p.provider_payment_id
  from appointment_payments p
  join appointments a on a.id = p.appointment_id
  where p.appointment_id = p_appt and p.status = 'aprovado'
    and (
      exists (select 1 from barbers b where b.id = auth.uid() and b.role in ('admin','vendas'))
      or a.barber_id = auth.uid()
    );
$$;
revoke all on function public.pagamento_online_do_agendamento(bigint) from public;
grant execute on function public.pagamento_online_do_agendamento(bigint) to authenticated;
