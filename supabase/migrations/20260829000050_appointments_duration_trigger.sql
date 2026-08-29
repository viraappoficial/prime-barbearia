-- Duração de agendamento sempre resolvida pela config canônica.
--
-- Revisão do Codex: `appointments.duration` não pode ter um DEFAULT fixo (ex.
-- 45) como regra efetiva — a fonte canônica é `shop_settings.slot_min`, e o
-- STAFF LEGADO continua fazendo INSERT direto (às vezes sem `duration`).
--
-- Trigger BEFORE INSERT: se `NEW.duration` vier NULL, preenche com o
-- `slot_min` ATUAL de shop_settings. Duração enviada explicitamente é
-- preservada. Sem DEFAULT fixo na coluna.
--
-- SECURITY INVOKER (não precisa escalar — shop_settings tem SELECT liberado);
-- `search_path` fixo e objeto qualificado.
--
-- Rollback:
--   drop trigger appointments_fill_duration on public.appointments;
--   drop function public._fill_appointment_duration();
-- Impacto no legado: INSERT de staff que omitia `duration` passa a gravar o
-- slot_min atual (antes gravava NULL). Mudança benigna e desejada — a
-- exclusion constraint do cutover precisa de duração não-nula.

create or replace function public._fill_appointment_duration()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.duration is null then
    new.duration := (select slot_min from public.shop_settings where id = 1);
  end if;
  return new;
end;
$$;

revoke all on function public._fill_appointment_duration() from public;

create trigger appointments_fill_duration
  before insert on public.appointments
  for each row
  execute function public._fill_appointment_duration();
