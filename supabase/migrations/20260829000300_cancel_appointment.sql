-- Cancelamento de agendamento pelo cliente.
--
-- Legado: caReagendar/caDoCancel fazem update status='cancelado' via
-- clients_update_own + insert de notificação pro barbeiro. Sem janela mínima,
-- sem penalidade. Esta RPC reproduz isso de forma controlada:
--   - só o dono (appointments.client_id = auth.uid());
--   - só se status in ('pendente','confirmado');
--   - update + notificação NA MESMA TRANSAÇÃO, sem envio externo.
--
-- SEM janela mínima de antecedência nesta fase (decisão). Política comercial
-- de no-show/antecedência = configuração futura (shop_settings tem espaço).
--
-- Rollback: drop function public.cancel_appointment(bigint);
-- Impacto: nenhum no legado. Nenhuma mudança de grant/policy.

create or replace function public.cancel_appointment(p_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_client uuid := auth.uid();
  v_appt   public.appointments%rowtype;
begin
  if v_client is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = 'P0001';
  end if;

  select * into v_appt from public.appointments where id = p_id;
  if not found or v_appt.client_id is distinct from v_client then
    raise exception 'NOT_FOUND' using errcode = 'P0001';   -- não vaza posse alheia
  end if;
  if v_appt.status not in ('pendente', 'confirmado') then
    raise exception 'NOT_CANCELABLE' using errcode = 'P0001';
  end if;

  update public.appointments set status = 'cancelado' where id = p_id;

  insert into public.notifications
    (for_role, recipient_barber_id, recipient_client_id, type, appt_id, text)
  values
    ('barber', v_appt.barber_id, null, 'cancelado', p_id,
     coalesce(v_appt.client_name, 'Cliente') || ' cancelou o horário de '
     || v_appt.day_label || ' às ' || v_appt.time);
end;
$$;

revoke execute on function public.cancel_appointment(bigint)
  from public, anon, authenticated, service_role;
grant execute on function public.cancel_appointment(bigint) to authenticated;
