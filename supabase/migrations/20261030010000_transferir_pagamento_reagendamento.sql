-- Reagendar com pagamento já feito: o pagamento aprovado muda do agendamento antigo para o novo, o novo fica "pago" e o antigo é cancelado.
-- Só o próprio cliente, nos dois agendamentos. Desfazer: drop function public.transferir_pagamento_reagendamento(bigint, bigint);
create or replace function public.transferir_pagamento_reagendamento(p_antigo bigint, p_novo bigint)
returns boolean
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); o record; n record;
begin
  if v_uid is null then return false; end if;
  select * into o from appointments where id = p_antigo for update;
  select * into n from appointments where id = p_novo for update;
  if o.id is null or n.id is null or o.id = n.id then return false; end if;
  if o.client_id is distinct from v_uid or n.client_id is distinct from v_uid then return false; end if;
  if o.payment_status <> 'pago' or o.status not in ('pendente', 'confirmado') then return false; end if;
  if n.payment_status not in ('nenhum', 'pendente') or n.status not in ('pendente', 'confirmado') then return false; end if;
  update appointment_payments set status = 'cancelado' where appointment_id = p_novo and status = 'pendente';
  update appointment_payments set appointment_id = p_novo where appointment_id = p_antigo and status = 'aprovado';
  update appointments set payment_status = 'pago', reserved_until = null where id = p_novo;
  update appointments set status = 'cancelado', payment_status = 'nenhum', reserved_until = null where id = p_antigo;
  return true;
end;
$$;
revoke all on function public.transferir_pagamento_reagendamento(bigint, bigint) from public, anon;
grant execute on function public.transferir_pagamento_reagendamento(bigint, bigint) to authenticated;
