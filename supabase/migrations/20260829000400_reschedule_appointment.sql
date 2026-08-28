-- Reagendamento ATÔMICO.
--
-- Legado: caReagendar cancela a linha e abre o wizard de novo — o cliente fica
-- sem horário nenhum no meio, e se o novo slot estiver ocupado ele perdeu o
-- antigo. Esta RPC faz tudo numa transação:
--   1. valida posse do agendamento antigo + status in ('pendente','confirmado');
--   2. cria o novo via public._insert_appointment (validação + trava + insert);
--      se QUALQUER coisa falhar (inclusive SLOT_TAKEN) -> ROLLBACK, o antigo
--      continua ativo;
--   3. só então marca o antigo como 'cancelado';
--   4. uma notificação ao barbeiro cobrindo a troca.
--
-- Nunca há janela intermediária de perda: ou a troca inteira dá certo, ou nada
-- muda.
--
-- Rollback: drop function public.reschedule_appointment(bigint, uuid, date, text, bigint[]);
-- Impacto: nenhum no legado. Nenhuma mudança de grant/policy.

create or replace function public.reschedule_appointment(
  p_id          bigint,
  p_barber_id   uuid,
  p_day         date,
  p_time        text,
  p_service_ids bigint[]
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_client uuid := auth.uid();
  v_old    public.appointments%rowtype;
  v_new_id bigint;
  v_lbl    text;
  v_name   text;
begin
  if v_client is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = 'P0001';
  end if;

  select * into v_old from public.appointments where id = p_id;
  if not found or v_old.client_id is distinct from v_client then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
  if v_old.status not in ('pendente', 'confirmado') then
    raise exception 'NOT_RESCHEDULABLE' using errcode = 'P0001';
  end if;

  -- cria o novo primeiro — se falhar, a transação inteira volta atrás
  v_new_id := public._insert_appointment(v_client, p_barber_id, p_day, p_time, p_service_ids);

  -- só agora cancela o antigo
  update public.appointments set status = 'cancelado' where id = p_id;

  select a.client_name, a.day_label into v_name, v_lbl
  from public.appointments a where a.id = v_new_id;
  v_name := coalesce(v_name, 'Cliente');

  -- notifica o barbeiro do NOVO horário
  insert into public.notifications
    (for_role, recipient_barber_id, recipient_client_id, type, appt_id, text)
  values
    ('barber', p_barber_id, null, 'novo', v_new_id,
     v_name || ' remarcou para ' || v_lbl || ' às ' || p_time);

  -- se trocou de barbeiro, avisa o antigo que o slot liberou
  if v_old.barber_id is distinct from p_barber_id then
    insert into public.notifications
      (for_role, recipient_barber_id, recipient_client_id, type, appt_id, text)
    values
      ('barber', v_old.barber_id, null, 'cancelado', p_id,
       v_name || ' remarcou e liberou ' || v_old.day_label || ' às ' || v_old.time);
  end if;

  return v_new_id;
end;
$$;

revoke all on function public.reschedule_appointment(bigint, uuid, date, text, bigint[]) from public;
grant execute on function public.reschedule_appointment(bigint, uuid, date, text, bigint[]) to authenticated;
