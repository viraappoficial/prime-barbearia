-- Encaixe do Zap: horário indisponível pode ser FORÇADO pela equipe, com confirmação na tela.
--
-- Hoje o gatilho _agenda_block_guard barra qualquer agendamento que colida com um bloqueio da
-- agenda (SLOT_BLOCKED) — inclusive encaixe de staff. Aqui:
--   1) staff_slot_conflicts(...)  — o que está atrapalhando aquele horário (bloqueio da agenda e/ou
--      agendamento já marcado), pra tela explicar o motivo antes de pedir a confirmação.
--      Admin vê o motivo escrito do bloqueio; vendas vê só o intervalo (agenda_blocks.reason é
--      interno e vendas não tem acesso à tabela — decisão D5 da migration 20260901000000).
--   2) staff_create_encaixe(...)  — cria o encaixe (confirmado, is_encaixe). Com p_force=true
--      libera o gatilho de bloqueio SÓ dentro desta chamada (flag local à transação, que o
--      navegador não consegue ligar). Sem p_force, se há conflito, recusa (SLOT_CONFLICT).
--   3) _agenda_block_guard — igual ao anterior, mais um desvio: respeita a flag acima.
--
-- Só admin e vendas. Cliente e barbeiro continuam barrados pelo gatilho como antes.
--
-- Rollback:
--   drop function public.staff_create_encaixe(uuid, date, text, text, integer, text[], text, uuid, text, text, boolean);
--   drop function public.staff_slot_conflicts(uuid, date, text, integer);
--   e reaplicar _agenda_block_guard da migration 20260901000000_agenda_blocks.sql
-- Impacto: nenhum no fluxo atual; só acrescenta capacidade pra admin/vendas.

-- ══ 1. gatilho: mesma lógica, com desvio controlado ══
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

  -- encaixe forçado pela equipe (staff_create_encaixe liga a flag só dentro da própria transação)
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

  return new;
end;
$$;
revoke execute on function public._agenda_block_guard() from public, anon, authenticated, service_role;

-- ══ 2. o que atrapalha esse horário ══
create or replace function public.staff_slot_conflicts(p_barber uuid, p_day date, p_time text, p_duration integer default 45)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_role   text;
  v_start  int;
  v_end    int;
  v_blocks jsonb;
  v_booked jsonb;
begin
  select b.role into v_role from public.barbers b where b.id = auth.uid();
  if v_role is null or v_role not in ('admin', 'vendas') then
    raise exception 'NOT_ALLOWED' using errcode = 'P0001';
  end if;

  v_start := public._hhmm_to_min_legacy(p_time);
  if v_start is null then
    raise exception 'INVALID_TIME' using errcode = 'P0001';
  end if;
  if coalesce(p_duration, 45) <= 0 then
    raise exception 'INVALID_DURATION' using errcode = 'P0001';
  end if;
  v_end := v_start + coalesce(p_duration, 45);

  select coalesce(jsonb_agg(jsonb_build_object(
           'kind', 'block', 'start', bl.start_time, 'end', bl.end_time,
           'reason', case when v_role = 'admin' then bl.reason end) order by bl.start_time), '[]'::jsonb)
  into v_blocks
  from public.agenda_blocks bl
  where bl.barber_id = p_barber and bl.day = p_day
    and public._hhmm_to_min_legacy(bl.start_time) < v_end
    and v_start < public._hhmm_to_min_legacy(bl.end_time);

  select coalesce(jsonb_agg(jsonb_build_object(
           'kind', 'booked', 'time', a.time, 'client', a.client_name, 'status', a.status) order by a.time), '[]'::jsonb)
  into v_booked
  from public.appointments a
  where a.barber_id = p_barber and a.day = p_day
    and a.status in ('pendente', 'confirmado')
    and public._hhmm_to_min_legacy(a.time) is not null
    and public._hhmm_to_min_legacy(a.time) < v_end
    and v_start < public._hhmm_to_min_legacy(a.time) + coalesce(a.duration, 45);

  return v_blocks || v_booked;
end;
$$;
revoke execute on function public.staff_slot_conflicts(uuid, date, text, integer) from public, anon, authenticated, service_role;
grant execute on function public.staff_slot_conflicts(uuid, date, text, integer) to authenticated;

-- ══ 3. cria o encaixe (opcionalmente forçando o horário) ══
create or replace function public.staff_create_encaixe(
  p_barber uuid, p_day date, p_day_label text, p_time text, p_duration integer,
  p_services text[], p_name text, p_client_id uuid, p_client_phone text, p_notes text,
  p_force boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role text;
  v_row  public.appointments%rowtype;
begin
  select b.role into v_role from public.barbers b where b.id = auth.uid();
  if v_role is null or v_role not in ('admin', 'vendas') then
    raise exception 'NOT_ALLOWED' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.barbers b where b.id = p_barber) then
    raise exception 'BAD_BARBER' using errcode = 'P0001';
  end if;
  if p_services is null or cardinality(p_services) = 0 then
    raise exception 'BAD_SERVICES' using errcode = 'P0001';
  end if;

  if not coalesce(p_force, false) then
    if jsonb_array_length(public.staff_slot_conflicts(p_barber, p_day, p_time, coalesce(p_duration, 45))) > 0 then
      raise exception 'SLOT_CONFLICT' using errcode = 'P0001';
    end if;
  else
    perform set_config('app.encaixe_force', 'on', true);   -- só nesta transação
  end if;

  insert into public.appointments
    (barber_id, day, day_label, time, duration, services, client_name, client_id, client_phone, notes, status, is_encaixe)
  values
    (p_barber, p_day, p_day_label, p_time, p_duration, p_services, p_name, p_client_id, p_client_phone, p_notes, 'confirmado', true)
  returning * into v_row;

  perform set_config('app.encaixe_force', 'off', true);
  return to_jsonb(v_row);
end;
$$;
revoke execute on function public.staff_create_encaixe(uuid, date, text, text, integer, text[], text, uuid, text, text, boolean) from public, anon, authenticated, service_role;
grant execute on function public.staff_create_encaixe(uuid, date, text, text, integer, text[], text, uuid, text, text, boolean) to authenticated;
