-- Disponibilidade pública real da agenda, agregada e SEM PII.
--
-- Hoje ninguém calcula disponibilidade real: o visitante nunca teve, e o
-- cliente logado só lê os próprios appointments (clients_select_own). Esta RPC
-- é a única forma de o público saber se um horário está livre — retornando
-- APENAS `slot` (HH:MM) e `livre boolean`. Nunca client_id, nome, barber_id,
-- contagem de barbeiros, nem qualquer coluna de appointments/clients.
--
-- "livre" é AGREGADO: o slot aparece livre se EXISTE algum barbeiro escalado
-- sem agendamento ativo nele. book_appointment REVALIDA, na transação, o
-- barbeiro específico escolhido, a escala dele e o slot.
--
-- Rollback:
--   drop function public.public_day_availability(date);
--   drop function public._barber_covers(jsonb, integer, integer, integer);
--   drop function public._hhmm_to_min(text);
-- Impacto: nenhum no legado. Não altera grants de appointments (a RPC roda como
-- owner e só devolve o booleano).

-- ── helper: "HH:MM" -> minutos desde 00:00 (puro) ──
create or replace function public._hhmm_to_min(p text)
returns integer
language sql
immutable
set search_path = ''
as $$
  select case
    when p ~ '^[0-2][0-9]:[0-5][0-9]$'
      then split_part(p, ':', 1)::int * 60 + split_part(p, ':', 2)::int
    else null
  end
$$;

-- ── helper: barbeiro cobre [slot, slot+slot_min] nesse dia da semana? ──
-- Espelha resolveBarberHours de domain/agenda.ts:
--   hours null                 -> usa a janela da loja
--   dia não é chave em hours    -> usa a janela da loja
--   hours[dia] presente         -> usa hours[dia] (pode ser null = folga)
create or replace function public._barber_covers(
  p_hours jsonb, p_dow integer, p_slot_start_min integer, p_slot_min integer
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  with resolvido as (
    select case
      when p_hours is null
        then (select open_hours -> p_dow::text from public.shop_settings where id = 1)
      when not (p_hours ? p_dow::text)
        then (select open_hours -> p_dow::text from public.shop_settings where id = 1)
      else p_hours -> p_dow::text
    end as janela
  )
  select coalesce(
    jsonb_typeof(janela) = 'array'
    and public._hhmm_to_min(janela ->> 0) <= p_slot_start_min
    and p_slot_start_min + p_slot_min <= public._hhmm_to_min(janela ->> 1),
    false
  )
  from resolvido
$$;

-- ── RPC pública ──
create or replace function public.public_day_availability(p_day date)
returns table(slot text, livre boolean)
language sql
stable
security definer
set search_path = ''
as $$
  with cfg as (
    select slot_min, open_hours, max_advance_days from public.shop_settings where id = 1
  ),
  ctx as (
    select
      (now() at time zone 'America/Sao_Paulo')::date as hoje,
      extract(hour   from now() at time zone 'America/Sao_Paulo') * 60
      + extract(minute from now() at time zone 'America/Sao_Paulo') as agora_min
  ),
  win as (
    select cfg.slot_min, cfg.open_hours -> (extract(dow from p_day)::int::text) as janela
    from cfg, ctx
    where p_day >= ctx.hoje
      and p_day <= ctx.hoje + cfg.max_advance_days
  ),
  slots as (
    select to_char(make_time(m / 60, m % 60, 0), 'HH24:MI') as slot, m as m0
    from win, ctx,
      lateral generate_series(
        public._hhmm_to_min(win.janela ->> 0),
        public._hhmm_to_min(win.janela ->> 1) - win.slot_min,
        win.slot_min
      ) as m
    where win.janela is not null
      and jsonb_typeof(win.janela) = 'array'
      and (p_day > ctx.hoje or m > ctx.agora_min)   -- hoje: sem slots que já passaram
  )
  select
    s.slot,
    exists (
      select 1
      from public.barbers b
      where b.is_barber = true
        and public._barber_covers(
              b.hours, extract(dow from p_day)::int, s.m0, (select slot_min from cfg)
            )
        and not exists (
          select 1 from public.appointments a
          where a.barber_id = b.id
            and a.day = p_day
            and a.time = s.slot
            and a.status in ('pendente', 'confirmado', 'concluido')
        )
    ) as livre
  from slots s
  order by s.slot
$$;

-- ── grants mínimos ──
revoke all on function public._hhmm_to_min(text) from public;
revoke all on function public._barber_covers(jsonb, integer, integer, integer) from public;
revoke all on function public.public_day_availability(date) from public;

grant execute on function public._hhmm_to_min(text) to anon, authenticated;
grant execute on function public._barber_covers(jsonb, integer, integer, integer) to anon, authenticated;
grant execute on function public.public_day_availability(date) to anon, authenticated;
