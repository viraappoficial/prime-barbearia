-- Criação de agendamento pelo cliente — caminho ÚNICO da agenda Prime Next.
--
-- Hoje o cliente insere direto: sb.from('appointments').insert(row) do browser,
-- com nome/preço/label calculados no cliente e ZERO trava de concorrência
-- (dois clientes pegam o mesmo horário). Esta migration cria:
--   - public._insert_appointment(...)  -> núcleo: valida no servidor + advisory
--     lock + checa disponibilidade + insere. Reusado pelo reschedule.
--   - public.book_appointment(...)      -> _insert_appointment + notificação.
--
-- Recebe só IDs (barbeiro, serviços) — nunca nome/preço do browser.
-- client_id := auth.uid() sempre. Erros de domínio: NOT_AUTHENTICATED,
-- PAST_DAY, OUT_OF_WINDOW, BAD_SLOT, SERVICE_INVALID, BARBER_OFF, SLOT_TAKEN.
--
-- O INSERT direto de `authenticated` só é revogado no CUTOVER
-- (20260829010000) — aqui a RPC passa a existir sem quebrar o legado.
--
-- Rollback:
--   drop function public.book_appointment(uuid, date, text, bigint[]);
--   drop function public._insert_appointment(uuid, uuid, date, text, bigint[]);
-- Impacto: nenhum no legado. Nenhuma mudança de grant/policy de tabela.

-- ── núcleo: validação + trava + insert (sem notificação) ──
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
  v_agora_min    int;
  v_names        text[];
  v_dur          int;
  v_svc_cnt      int;
  v_client_name  text;
  v_client_email text;
  v_day_label    text;
  v_id           bigint;
begin
  if p_client is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = 'P0001';
  end if;

  select * into v_cfg from public.shop_settings where id = 1;
  v_janela := v_cfg.open_hours -> v_dow::text;
  v_agora_min := extract(hour   from now() at time zone 'America/Sao_Paulo') * 60
              +  extract(minute from now() at time zone 'America/Sao_Paulo');

  -- 1. dia: no futuro e dentro da janela
  if p_day < (now() at time zone 'America/Sao_Paulo')::date then
    raise exception 'PAST_DAY' using errcode = 'P0001';
  end if;
  if p_day > (now() at time zone 'America/Sao_Paulo')::date + v_cfg.max_advance_days then
    raise exception 'OUT_OF_WINDOW' using errcode = 'P0001';
  end if;

  -- 2. horário: formato + dentro da grade do dia
  v_start := public._hhmm_to_min(p_time);
  if v_start is null
     or v_janela is null or jsonb_typeof(v_janela) <> 'array'
     or v_start < public._hhmm_to_min(v_janela ->> 0)
     or v_start + v_cfg.slot_min > public._hhmm_to_min(v_janela ->> 1)
     or (v_start - public._hhmm_to_min(v_janela ->> 0)) % v_cfg.slot_min <> 0 then
    raise exception 'BAD_SLOT' using errcode = 'P0001';
  end if;
  if p_day = (now() at time zone 'America/Sao_Paulo')::date and v_start <= v_agora_min then
    raise exception 'PAST_DAY' using errcode = 'P0001';
  end if;

  -- 3. serviços: existem e ativos; nomes/duração vêm do BANCO
  select array_agg(s.name order by s.display_order),
         coalesce(sum(s.duration_min), v_cfg.slot_min),
         count(*)
    into v_names, v_dur, v_svc_cnt
  from public.services s
  where s.id = any(p_service_ids) and s.active = true;
  if coalesce(v_svc_cnt, 0) = 0
     or v_svc_cnt <> coalesce(array_length(p_service_ids, 1), 0) then
    raise exception 'SERVICE_INVALID' using errcode = 'P0001';
  end if;

  -- 4. barbeiro: existe, atende, escalado nesse slot
  if not exists (
    select 1 from public.barbers b where b.id = p_barber_id and b.is_barber = true
  ) then
    raise exception 'BARBER_OFF' using errcode = 'P0001';
  end if;
  if not public._barber_covers(
       (select hours from public.barbers where id = p_barber_id),
       v_dow, v_start, v_cfg.slot_min
     ) then
    raise exception 'BARBER_OFF' using errcode = 'P0001';
  end if;

  -- 5. serializa concorrentes no mesmo (barbeiro, dia, hora)
  perform pg_advisory_xact_lock(
    hashtextextended(p_barber_id::text || '|' || p_day::text || '|' || p_time, 0)
  );

  -- 6. disponibilidade (o índice único do cutover é a rede definitiva)
  if exists (
    select 1 from public.appointments a
    where a.barber_id = p_barber_id and a.day = p_day and a.time = p_time
      and a.status in ('pendente', 'confirmado', 'concluido')
  ) then
    raise exception 'SLOT_TAKEN' using errcode = 'P0001';
  end if;

  -- 7. dados do cliente + rótulo do dia (servidor)
  select coalesce(c.name, c.email, 'Cliente'), c.email
    into v_client_name, v_client_email
  from public.clients c where c.id = p_client;
  v_client_name := coalesce(v_client_name, 'Cliente');
  v_day_label := (array['Dom','Seg','Ter','Qua','Qui','Sex','Sáb'])[v_dow + 1]
                 || ' ' || to_char(p_day, 'DD/MM');

  -- 8. insere
  insert into public.appointments
    (client_id, barber_id, services, day, day_label, time, duration,
     status, is_encaixe, client_name, client_email)
  values
    (p_client, p_barber_id, v_names, p_day, v_day_label, p_time, v_dur,
     'pendente', false, v_client_name, v_client_email)
  returning id into v_id;

  return v_id;

exception
  when unique_violation then
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
-- _insert_appointment: só chamado internamente pelas outras RPCs (como owner).
grant execute on function public.book_appointment(uuid, date, text, bigint[]) to authenticated;
