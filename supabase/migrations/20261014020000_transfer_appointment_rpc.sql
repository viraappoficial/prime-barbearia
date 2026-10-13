-- Transferir agendamento pra outro profissional (e, junto, trocar o serviço), com permissão e conferência no banco.
--
-- Por que uma função: pela RLS de hoje, o barbeiro comum só atualiza agendamento DELE e só se continuar sendo dele
-- (barbers_update_own: with check barber_id = auth.uid()), então transferir direto pela tabela é recusado; admin e vendas
-- conseguem (admin_update_all / appointments_vendas_update). A função abre essa exceção só pra esta operação:
--   - quem pode: admin, vendas, ou o barbeiro dono do agendamento;
--   - só agendamento pendente/confirmado e que não começou (iniciado_em nulo);
--   - o profissional novo precisa existir, atender clientes e NÃO ter outro agendamento ativo no mesmo dia/horário;
--   - bloqueio de agenda do profissional novo: já barrado pelo gatilho appointments_agenda_block_guard (SLOT_BLOCKED);
--   - p_services (opcional) troca o serviço na MESMA operação (tudo ou nada).
-- O aviso de WhatsApp ao barbeiro novo vem do gatilho da migration 20261014010000_transferir_agendamento_aviso.sql.
-- Erros (P0001): NOT_ALLOWED, NOT_FOUND, BAD_STATUS, BAD_BARBER, BARBER_BUSY, SLOT_BLOCKED.
--
-- Rollback: drop function public.transfer_appointment(bigint, uuid, text[]);
-- Impacto: só acrescenta a função; nada do fluxo atual muda.

create or replace function public.transfer_appointment(p_appointment_id bigint, p_new_barber_id uuid, p_services text[] default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  a      public.appointments%rowtype;
  v_role text;
begin
  if auth.uid() is null then
    raise exception 'NOT_ALLOWED' using errcode = 'P0001';
  end if;

  select * into a from public.appointments where id = p_appointment_id for update;
  if not found then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;

  select b.role into v_role from public.barbers b where b.id = auth.uid();
  if not (coalesce(v_role, '') in ('admin', 'vendas') or a.barber_id = auth.uid()) then
    raise exception 'NOT_ALLOWED' using errcode = 'P0001';
  end if;

  if a.status not in ('pendente', 'confirmado') or a.iniciado_em is not null then
    raise exception 'BAD_STATUS' using errcode = 'P0001';
  end if;

  if p_new_barber_id is null
     or not exists (select 1 from public.barbers nb where nb.id = p_new_barber_id and coalesce(nb.is_barber, true)) then
    raise exception 'BAD_BARBER' using errcode = 'P0001';
  end if;

  if p_services is not null and coalesce(array_length(p_services, 1), 0) = 0 then
    raise exception 'BAD_SERVICES' using errcode = 'P0001';
  end if;

  if a.barber_id is not distinct from p_new_barber_id then
    if p_services is not null then
      update public.appointments set services = p_services where id = a.id;
    end if;
    return;
  end if;

  if exists (
    select 1 from public.appointments o
    where o.barber_id = p_new_barber_id
      and o.day = a.day
      and o.time = a.time
      and o.id <> a.id
      and o.status not in ('cancelado', 'nao_compareceu')
  ) then
    raise exception 'BARBER_BUSY' using errcode = 'P0001';
  end if;

  update public.appointments
     set barber_id = p_new_barber_id,
         services  = coalesce(p_services, services)
   where id = a.id;
end;
$$;

revoke all on function public.transfer_appointment(bigint, uuid, text[]) from public, anon;
grant execute on function public.transfer_appointment(bigint, uuid, text[]) to authenticated;
