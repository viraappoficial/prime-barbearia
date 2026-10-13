-- Transferir agendamento para outro profissional: o aviso ao barbeiro (barber_notices) acompanha o profissional novo.
-- Sem isto, o aviso de um agendamento pendente continuaria apontando pro barbeiro ANTERIOR (a linha só é criada no INSERT),
-- e o barbeiro novo nunca seria avisado pelo WhatsApp.
--
-- Quando o barber_id de um agendamento PENDENTE muda:
--   - o aviso passa pro barbeiro novo, volta a "pendente", ganha token novo (o link do barbeiro antigo deixa de valer),
--     e zera os envios (sent_at, lembretes) pra ele receber como se fosse um agendamento novo;
--   - se não existia aviso (ex.: não era pendente na criação), cria um.
-- Agendamento confirmado/encaixe não gera aviso (igual ao INSERT). Erro aqui é engolido: trocar de profissional nunca falha por isso.
--
-- Rollback:
--   drop trigger appointments_barber_notice_transfer on public.appointments;
--   drop function public._barber_notice_on_barber_change();
-- Impacto: só quando barber_id muda; o fluxo atual (agendar, confirmar, remarcar) não é tocado.

create or replace function public._barber_notice_on_barber_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.barber_id is not null and new.status = 'pendente' and not coalesce(new.is_encaixe, false) then
    update public.barber_notices
       set barber_id = new.barber_id,
           status = 'pending',
           token = replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
           sent_at = null,
           reminders_sent = 0,
           last_reminder_at = null,
           resolved_at = null,
           proposed_day = null,
           proposed_time = null,
           expires_at = now() + interval '7 days'
     where appointment_id = new.id;
    if not found then
      insert into public.barber_notices (appointment_id, barber_id) values (new.id, new.barber_id)
      on conflict (appointment_id) do nothing;
    end if;
  end if;
  return new;
exception when others then
  return new;
end;
$$;
revoke execute on function public._barber_notice_on_barber_change() from public, anon, authenticated, service_role;

drop trigger if exists appointments_barber_notice_transfer on public.appointments;
create trigger appointments_barber_notice_transfer
  after update of barber_id on public.appointments
  for each row
  when (old.barber_id is distinct from new.barber_id)
  execute function public._barber_notice_on_barber_change();
