-- Bloqueio de agenda (staff) já existe em produção há tempo — ver
-- `20260901000000_agenda_blocks.sql` (tabela `agenda_blocks`, guard trigger
-- `_agenda_block_guard` em `appointments`, RPC pública `agenda_blocked_ranges`).
-- Essa migration só existe no lab-first do Prime Next: PORTA o bloqueio pro
-- lado do CLIENTE (Next) — `public_day_availability` (que o legado não tem;
-- é construção própria do Next pro wizard) precisa também excluir horário
-- bloqueado, senão o slot aparece "livre" na grade e o cliente só descobre o
-- bloqueio ao tentar reservar (erro `SLOT_BLOCKED`, agora traduzido em
-- `domain/agenda.ts` como `horario_bloqueado`) — pior UX, mesmo não sendo
-- furo de segurança (o guard trigger já barra a escrita de qualquer jeito).
--
-- Só soma UMA condição a mais no `not exists` que já existe pra
-- `appointments` — mesmo formato HH:MM, mesma semântica de sobreposição de
-- intervalo. Nenhuma mudança de shape/contrato da função.
--
-- Rollback: reaplicar a definição anterior de `public_day_availability`
-- (sem a condição de `agenda_blocks`) — ver commit anterior a este no
-- histórico do lab.

create or replace function public.public_day_availability(p_day date, p_service_ids bigint[])
returns table (slot text, livre boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_dur integer;
begin
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
        public._hhmm_to_min(win.janela ->> 1) - v_dur,
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
        and not exists (
          select 1 from public.agenda_blocks bl
          where bl.barber_id = b.id
            and bl.day = p_day
            and public._hhmm_to_min(bl.start_time) < s.m0 + v_dur
            and s.m0 < public._hhmm_to_min(bl.end_time)
        )
    ) as livre
  from s
  order by s.slot;
end;
$$;
