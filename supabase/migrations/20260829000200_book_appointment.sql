-- Criação de agendamento pelo cliente — caminho ÚNICO da agenda Prime Next.
--
-- Correções incorporadas:
--  - duração/sobreposição: valida o intervalo [início, início + duração_total);
--  - fuso: shop_settings.timezone;
--  - staff: usuário com linha em `barbers` -> STAFF_NOT_ALLOWED (no núcleo);
--  - serviços: validação única via public._validate_services (lista não vazia,
--    sem duplicata, todos existem/ativos, contagem = cardinalidade);
--  - perfil: cliente sem linha em public.clients -> PROFILE_REQUIRED (não erro
--    de FK). A UI futura direciona para completar/reconciliar o perfil.
--
-- Recebe só IDs (barbeiro, serviços) — nunca nome/preço do browser.
-- client_id := auth.uid() sempre. Erros de domínio: NOT_AUTHENTICATED,
-- STAFF_NOT_ALLOWED, PROFILE_REQUIRED, PAST_DAY, OUT_OF_WINDOW, BAD_SLOT,
-- SERVICE_INVALID, BARBER_OFF, SLOT_TAKEN.
--
-- Rollback:
--   drop function public.book_appointment(uuid, date, text, bigint[]);
--   drop function public._insert_appointment(uuid, uuid, date, text, bigint[]);
-- Impacto: nenhum no legado. Nenhuma mudança de grant/policy de tabela.

-- ── núcleo: validação + intervalo + insert (sem notificação) ──
create or replace function public._insert_appointment(
  p_client      uuid,
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
  v_cfg          public.shop_settings%rowtype;
  v_dow          int  := extract(dow from p_day)::int;
  v_janela       jsonb;
  v_start        int;
  v_now          timestamp;
  v_names        text[];
  v_dur          int;
  v_client_name  text;
  v_client_email text;
  v_day_label    text;
  v_id           bigint;
begin
  if p_client is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = 'P0001';
  end if;

  -- staff nunca agenda pelo caminho do cliente
  if exists (select 1 from public.barbers b where b.id = p_client) then
    raise exception 'STAFF_NOT_ALLOWED' using errcode = 'P0001';
  end if;

  -- perfil de cliente obrigatório (sem erro de FK)
  select coalesce(c.name, c.email, 'Cliente'), c.email
    into v_client_name, v_client_email
  from public.clients c where c.id = p_client;
  if not found then
    raise exception 'PROFILE_REQUIRED' using errcode = 'P0001';
  end if;
  v_client_name := coalesce(v_client_name, 'Cliente');

  select * into v_cfg from public.shop_settings where id = 1;
  v_janela := v_cfg.open_hours -> v_dow::text;
  v_now := now() at time zone v_cfg.timezone;

  -- 1. dia: no futuro e dentro da janela
  if p_day < v_now::date then
    raise exception 'PAST_DAY' using errcode = 'P0001';
  end if;
  if p_day > v_now::date + v_cfg.max_advance_days then
    raise exception 'OUT_OF_WINDOW' using errcode = 'P0001';
  end if;

  -- 2. serviços: mesma semântica de public_day_availability; duração TOTAL do banco
  select o_names, o_dur into v_names, v_dur from public._validate_services(p_service_ids);

  -- 3. horário: formato + na grade + o intervalo inteiro cabe na janela do dia
  v_start := public._hhmm_to_min(p_time);
  if v_start is null
     or v_janela is null or jsonb_typeof(v_janela) <> 'array'
     or v_start < public._hhmm_to_min(v_janela ->> 0)
     or v_start + v_dur > public._hhmm_to_min(v_janela ->> 1)
     or (v_start - public._hhmm_to_min(v_janela ->> 0)) % v_cfg.slot_min <> 0 then
    raise exception 'BAD_SLOT' using errcode = 'P0001';
  end if;
  if p_day = v_now::date
     and v_start <= extract(hour from v_now) * 60 + extract(minute from v_now) then
    raise exception 'PAST_DAY' using errcode = 'P0001';
  end if;

  -- 4. barbeiro: existe, atende, escala cobre [v_start, v_start + v_dur]
  if not exists (
    select 1 from public.barbers b where b.id = p_barber_id and b.is_barber = true
  ) then
    raise exception 'BARBER_OFF' using errcode = 'P0001';
  end if;
  if not public._barber_covers(
       (select hours from public.barbers where id = p_barber_id),
       v_dow, v_start, v_dur
     ) then
    raise exception 'BARBER_OFF' using errcode = 'P0001';
  end if;

  -- 5. serializa concorrentes que disputam o mesmo barbeiro/dia
  perform pg_advisory_xact_lock(
    hashtextextended(p_barber_id::text || '|' || p_day::text, 0)
  );

  -- 6. sobreposição de intervalo com agendamento ATIVO do mesmo barbeiro
  --    [x, x+dx) e [v_start, v_start+v_dur) se cruzam?  (a exclusion constraint
  --    do cutover é a rede definitiva)
  if exists (
    select 1 from public.appointments a
    where a.barber_id = p_barber_id
      and a.day = p_day
      and a.status in ('pendente', 'confirmado')
      and public._hhmm_to_min(a.time) < v_start + v_dur
      and v_start < public._hhmm_to_min(a.time) + coalesce(a.duration, v_cfg.slot_min)
  ) then
    raise exception 'SLOT_TAKEN' using errcode = 'P0001';
  end if;

  -- 7. rótulo do dia (servidor)
  v_day_label := (array['Dom','Seg','Ter','Qua','Qui','Sex','Sáb'])[v_dow + 1]
                 || ' ' || to_char(p_day, 'DD/MM');

  -- 8. insere (duração real gravada)
  insert into public.appointments
    (client_id, barber_id, services, day, day_label, time, duration,
     status, is_encaixe, client_name, client_email)
  values
    (p_client, p_barber_id, v_names, p_day, v_day_label, p_time, v_dur,
     'pendente', false, v_client_name, v_client_email)
  returning id into v_id;

  return v_id;

exception
  when unique_violation or exclusion_violation then
    raise exception 'SLOT_TAKEN' using errcode = 'P0001';
end;
$$;

-- ── RPC do cliente ──
create or replace function public.book_appointment(
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
  v_id   bigint;
  v_name text;
  v_lbl  text;
begin
  v_id := public._insert_appointment(auth.uid(), p_barber_id, p_day, p_time, p_service_ids);

  select a.client_name, a.day_label into v_name, v_lbl
  from public.appointments a where a.id = v_id;

  insert into public.notifications
    (for_role, recipient_barber_id, recipient_client_id, type, appt_id, text)
  values
    ('barber', p_barber_id, null, 'novo', v_id,
     v_name || ' agendou ' || v_lbl || ' às ' || p_time);

  return v_id;
end;
$$;

-- ── grants mínimos ──
revoke all on function public._insert_appointment(uuid, uuid, date, text, bigint[]) from public;
revoke all on function public.book_appointment(uuid, date, text, bigint[]) from public;
grant execute on function public.book_appointment(uuid, date, text, bigint[]) to authenticated;
