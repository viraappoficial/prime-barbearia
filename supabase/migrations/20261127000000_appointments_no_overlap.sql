-- Trava contra dois agendamentos ativos sobrepostos no mesmo barbeiro/dia.
-- Antes só a tela escondia o horário; dois clientes simultâneos conseguiam marcar o mesmo.
-- Estende _agenda_block_guard: depois do desvio de encaixe forçado e do bloqueio de agenda,
-- recusa (SLOT_TAKEN) se já há pendente/confirmado cruzando o intervalo. Serializa por barbeiro+dia
-- com advisory lock pra fechar a corrida entre duas transações.
-- Rollback: reaplicar _agenda_block_guard da migration 20261010000000_staff_encaixe_forcado.sql
create or replace function public._agenda_block_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_new_active   boolean;
  v_was_same_occ boolean;
  v_start        int;
  v_end          int;
  v_duration     int;
begin
  v_new_active := new.status in ('pendente', 'confirmado');
  if not v_new_active then
    return new;
  end if;

  if tg_op = 'UPDATE' then
    v_was_same_occ :=
      old.status in ('pendente', 'confirmado')
      and old.barber_id is not distinct from new.barber_id
      and old.day       is not distinct from new.day
      and old.time      is not distinct from new.time
      and coalesce(old.duration, 45) = coalesce(new.duration, 45);
    if v_was_same_occ then
      return new;
    end if;
  end if;

  v_start := public._hhmm_to_min_legacy(new.time);
  if v_start is null then
    raise exception 'INVALID_TIME' using errcode = 'P0001';
  end if;

  v_duration := coalesce(new.duration, 45);
  if v_duration <= 0 then
    raise exception 'INVALID_DURATION' using errcode = 'P0001';
  end if;
  v_end := v_start + v_duration;

  if coalesce(current_setting('app.encaixe_force', true), '') = 'on' then
    return new;
  end if;

  if exists (
    select 1
    from public.agenda_blocks bl
    where bl.barber_id = new.barber_id
      and bl.day = new.day
      and public._hhmm_to_min_legacy(bl.start_time) < v_end
      and v_start < public._hhmm_to_min_legacy(bl.end_time)
  ) then
    raise exception 'SLOT_BLOCKED' using errcode = 'P0001';
  end if;

  if new.barber_id is not null then
    perform pg_advisory_xact_lock(hashtext(new.barber_id::text || new.day::text));
    if exists (
      select 1
      from public.appointments a
      where a.barber_id = new.barber_id
        and a.day = new.day
        and a.id is distinct from new.id
        and a.status in ('pendente', 'confirmado')
        and public._hhmm_to_min_legacy(a.time) is not null
        and public._hhmm_to_min_legacy(a.time) < v_end
        and v_start < public._hhmm_to_min_legacy(a.time) + coalesce(a.duration, 45)
    ) then
      raise exception 'SLOT_TAKEN' using errcode = 'P0001';
    end if;
  end if;

  return new;
end;
$$;
revoke execute on function public._agenda_block_guard() from public, anon, authenticated, service_role;
