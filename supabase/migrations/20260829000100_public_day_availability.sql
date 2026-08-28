-- Disponibilidade pública real da agenda, agregada, SEM PII e com DURAÇÃO.
--
-- Correção de bug (revisão do Codex): a agenda não é slot fixo — os serviços
-- têm durações de 15 a 150 min. Um atendimento de 90 min às 09:00 ocupa até
-- 10:30; a RPC precisa considerar o intervalo [início, início+duração), não só
-- o horário inicial.
--
-- Recebe os IDs dos serviços (mesma base do book_appointment) e calcula a
-- duração total no servidor. Retorna APENAS `slot` (HH:MM) + `livre boolean`.
-- Nunca client_id, nome, barber_id, contagem, nem coluna de appointments.
--
-- `livre` é AGREGADO: aparece livre se EXISTE algum barbeiro cuja escala cobre
-- o intervalo inteiro E que não tem intervalo ativo sobreposto.
-- book_appointment REVALIDA o barbeiro específico, a escala e o intervalo.
--
-- Rollback:
--   drop function public.public_day_availability(date, bigint[]);
--   drop function public._barber_covers(jsonb, integer, integer, integer);
--   drop function public._hhmm_to_min(text);
-- Impacto: nenhum no legado. Não altera grants de appointments.

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

-- ── helper: a escala do barbeiro cobre [slot_start, slot_start + dur]? ──
-- Espelha resolveBarberHours de domain/agenda.ts:
--   hours null                 -> usa a janela da loja
--   dia não é chave em hours    -> usa a janela da loja
--   hours[dia] presente         -> usa hours[dia] (pode ser null = folga)
create or replace function public._barber_covers(
  p_hours jsonb, p_dow integer, p_slot_start_min integer, p_duration_min integer
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
    and p_slot_start_min + p_duration_min <= public._hhmm_to_min(janela ->> 1),
    false
  )
  from resolvido
$$;

-- ── RPC pública ──
create or replace function public.public_day_availability(p_day date, p_service_ids bigint[])
returns table(slot text, livre boolean)
language sql
stable
security definer
set search_path = ''
as $$
  with cfg as (
    select slot_min, open_hours, max_advance_days, timezone from public.shop_settings where id = 1
  ),
  dur as (
    select coalesce(
      (select sum(s.duration_min) from public.services s
        where s.id = any(p_service_ids) and s.active = true),
      (select slot_min from cfg)
    )::int as total
  ),
  ctx as (
    select
      (now() at time zone (select timezone from cfg))::date as hoje,
      (extract(hour   from now() at time zone (select timezone from cfg)) * 60
     + extract(minute from now() at time zone (select timezone from cfg)))::int as agora_min
  ),
  win as (
    select cfg.slot_min, cfg.open_hours -> (extract(dow from p_day)::int::text) as janela
    from cfg, ctx
    where p_day >= ctx.hoje
      and p_day <= ctx.hoje + cfg.max_advance_days
  ),
  slots as (
    select to_char(make_time(m / 60, m % 60, 0), 'HH24:MI') as slot, m as m0
    from win, ctx, dur,
      lateral generate_series(
        public._hhmm_to_min(win.janela ->> 0),
        public._hhmm_to_min(win.janela ->> 1) - dur.total,   -- cabe a duração inteira antes de fechar
        win.slot_min
      ) as m
    where win.janela is not null
      and jsonb_typeof(win.janela) = 'array'
      and (p_day > ctx.hoje or m > ctx.agora_min)
  )
  select
    s.slot,
    exists (
      select 1
      from public.barbers b, dur, cfg
      where b.is_barber = true
        and public._barber_covers(b.hours, extract(dow from p_day)::int, s.m0, dur.total)
        and not exists (
          select 1 from public.appointments a
          where a.barber_id = b.id
            and a.day = p_day
            and a.status in ('pendente', 'confirmado')
            -- intervalos [x, x+dx) e [s.m0, s.m0+dur) se sobrepõem?
            and public._hhmm_to_min(a.time) < s.m0 + dur.total
            and s.m0 < public._hhmm_to_min(a.time) + coalesce(a.duration, cfg.slot_min)
        )
    ) as livre
  from slots s
  order by s.slot
$$;

-- ── grants mínimos (revisão do Codex) ──
-- SÓ a RPC pública é executável por anon/authenticated. Os helpers são
-- chamados internamente pelas RPCs SECURITY DEFINER (como owner), nunca direto.
revoke all on function public._hhmm_to_min(text) from public;
revoke all on function public._barber_covers(jsonb, integer, integer, integer) from public;
revoke all on function public.public_day_availability(date, bigint[]) from public;

grant execute on function public.public_day_availability(date, bigint[]) to anon, authenticated;
