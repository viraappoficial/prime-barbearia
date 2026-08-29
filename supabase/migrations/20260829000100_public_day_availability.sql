-- Disponibilidade pública real da agenda, agregada, SEM PII e com DURAÇÃO.
--
-- A agenda não é slot fixo (services.duration_min de 15 a 150 min). A RPC
-- considera o intervalo [início, início + duração_total), não só o horário.
--
-- Revisão do Codex (2ª): a validação de serviços aqui tem a MESMA semântica de
-- book_appointment (helper compartilhado _validate_services):
--   - lista não vazia;
--   - sem IDs duplicados;
--   - todos existem e estão ativos;
--   - contagem encontrada = cardinalidade recebida.
-- ID inválido -> erro SERVICE_INVALID (não calcula duração parcial).
--
-- Retorna APENAS `slot` (HH:MM) + `livre boolean`. Nunca client_id, nome,
-- barber_id, contagem, nem coluna de appointments/clients.
--
-- `livre` é AGREGADO: aparece livre se EXISTE algum barbeiro cuja escala cobre
-- o intervalo inteiro E que não tem intervalo ativo sobreposto.
-- book_appointment REVALIDA o barbeiro específico, a escala e o intervalo.
--
-- Rollback:
--   drop function public.public_day_availability(date, bigint[]);
--   drop function public._validate_services(bigint[]);
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

-- ── helper: valida os serviços e devolve nomes + duração total ──
-- Semântica única (usada por public_day_availability e _insert_appointment).
create or replace function public._validate_services(
  p_service_ids bigint[],
  out o_names text[],
  out o_dur   integer
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_card     integer;
  v_distinct integer;
  v_found    integer;
begin
  select count(*), count(distinct e) into v_card, v_distinct
  from unnest(coalesce(p_service_ids, '{}'::bigint[])) e;

  if v_card = 0 or v_card <> v_distinct then
    raise exception 'SERVICE_INVALID' using errcode = 'P0001';   -- vazio ou com duplicata
  end if;

  select array_agg(s.name order by s.display_order), sum(s.duration_min), count(*)
    into o_names, o_dur, v_found
  from public.services s
  where s.id = any(p_service_ids) and s.active = true;

  if coalesce(v_found, 0) <> v_distinct then
    raise exception 'SERVICE_INVALID' using errcode = 'P0001';   -- algum id não existe ou inativo
  end if;
end;
$$;

-- ── helper: a escala do barbeiro cobre [slot_start, slot_start + dur]? ──
-- Espelha resolveBarberHours de domain/agenda.ts:
--   hours null / dia não é chave  -> janela da loja
--   hours[dia] presente           -> hours[dia] (pode ser null = folga)
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
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_dur integer;
begin
  -- valida com a mesma semântica do book_appointment; ID inválido -> SERVICE_INVALID
  select o_dur into v_dur from public._validate_services(p_service_ids);

  return query
  with cfg as (
    select slot_min, open_hours, max_advance_days, timezone from public.shop_settings where id = 1
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
  s as (
    select to_char(make_time(m / 60, m % 60, 0), 'HH24:MI') as slot, m as m0
    from win, ctx,
      lateral generate_series(
        public._hhmm_to_min(win.janela ->> 0),
        public._hhmm_to_min(win.janela ->> 1) - v_dur,   -- cabe a duração inteira antes de fechar
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
      from public.barbers b, cfg
      where b.is_barber = true
        and public._barber_covers(b.hours, extract(dow from p_day)::int, s.m0, v_dur)
        and not exists (
          select 1 from public.appointments a
          where a.barber_id = b.id
            and a.day = p_day
            and a.status in ('pendente', 'confirmado')
            and public._hhmm_to_min(a.time) < s.m0 + v_dur
            and s.m0 < public._hhmm_to_min(a.time) + coalesce(a.duration, cfg.slot_min)
        )
    ) as livre
  from s
  order by s.slot;
end;
$$;

-- ── grants mínimos (revisão do Codex) ──
-- SÓ a RPC pública é executável por role externa. Os helpers rodam como owner
-- dentro das RPCs SECURITY DEFINER.
-- os default privileges do Supabase concedem EXECUTE a anon/authenticated/
-- service_role em toda função nova de `public`; revogar explicitamente dos
-- helpers (só o owner os chama de dentro das RPCs SECURITY DEFINER).
revoke execute on function public._hhmm_to_min(text)
  from public, anon, authenticated, service_role;
revoke execute on function public._validate_services(bigint[])
  from public, anon, authenticated, service_role;
revoke execute on function public._barber_covers(jsonb, integer, integer, integer)
  from public, anon, authenticated, service_role;

revoke execute on function public.public_day_availability(date, bigint[])
  from public, anon, authenticated, service_role;
grant execute on function public.public_day_availability(date, bigint[]) to anon, authenticated;
