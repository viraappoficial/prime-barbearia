-- ST-1b.1 — núcleo comum de INSERT de agendamento de STAFF + helper de posse.
--
-- `_insert_appointment` (agenda do cliente) recusa staff (`STAFF_NOT_ALLOWED`) e
-- exige `public.clients` (`PROFILE_REQUIRED`) — nenhum dos dois serve para o
-- encaixe walk-in. Este núcleo ESPELHA a validação de `_insert_appointment`
-- (mesma grade da loja, mesmo `_barber_covers`, mesma checagem de intervalo) com
-- as diferenças de staff:
--   - NÃO checa `barbers` do chamador; NÃO exige `public.clients`
--     (`p_client_id` pode ser NULL — walk-in);
--   - recebe SERVIÇOS JÁ RESOLVIDOS no servidor: `p_service_names` +
--     `p_duration` (a RPC chamadora resolve — encaixe via `_validate_services`,
--     reschedule via a linha antiga). O browser NUNCA manda nome/preço/duração;
--   - `status` e `is_encaixe` parametrizados; `notes` gravável;
--   - `p_grid_aligned` liga/desliga só a checagem `% slot_min` (reschedule =
--     grade obrigatória; encaixe = fora da grade). A janela da loja e a escala
--     do barbeiro valem SEMPRE.
--   - SEM `p_exclude_id`: o reschedule cancela a linha antiga NA MESMA
--     TRANSAÇÃO antes de chamar o núcleo, então ela já não conta; o encaixe não
--     exclui nada. O núcleo SEMPRE considera todos os agendamentos ativos.
--
-- `duration` de agenda ativa NUNCA é comparada com NULL nem sofre fallback
-- (§ ST-1b.0): se um ativo do barbeiro/dia tem `duration IS NULL`, o núcleo
-- levanta `OVERLAP_UNCHECKED` e NÃO insere.
--
-- Locks: `pg_advisory_xact_lock` com chave `'agenda|<barber>|<dia>'` — namespace
-- distinto do lock `'crm|…'` do `staff_book_encaixe`; ambos vivem na mesma
-- transação da RPC.
--
-- Ambas as funções: `SECURITY DEFINER`, `search_path=''`, objetos `public.`/`auth.`
-- qualificados, `revoke execute` de todos e **sem grant** — só o owner (postgres)
-- as chama, de dentro das RPCs `staff_reschedule_appointment` / `staff_book_encaixe`.
--
-- Rollback:
--   drop function public._staff_insert_appointment(uuid, date, text, text[], int, uuid, text, text, boolean, text, text, boolean);
--   drop function public._staff_can_book_for(uuid, boolean);
-- Impacto no legado: nenhum — funções novas, ninguém chama até ST-1b.2/.3.

-- ── helper de posse: pode agendar EM NOME DE `p_barber_id`? ──────────────────
create or replace function public._staff_can_book_for(p_barber_id uuid, p_allow_vendas boolean)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_role text;
begin
  if v_uid is null then
    raise exception 'NOT_AUTH' using errcode = 'P0001';
  end if;
  v_role := public.barber_role();
  if v_role is null then
    raise exception 'NOT_STAFF' using errcode = 'P0001';
  end if;
  -- barbeiro só a própria agenda; admin sempre; vendas quando a operação permite
  if not (
       p_barber_id = v_uid
    or v_role = 'admin'
    or (p_allow_vendas and v_role = 'vendas')
  ) then
    raise exception 'NOT_ALLOWED' using errcode = 'P0001';
  end if;
end;
$$;

revoke execute on function public._staff_can_book_for(uuid, boolean)
  from public, anon, authenticated, service_role;

-- ── núcleo: validação + intervalo + insert (sem notificação) ────────────────
create or replace function public._staff_insert_appointment(
  p_barber_id     uuid,
  p_day           date,
  p_time          text,
  p_service_names text[],   -- JÁ resolvidos (nunca do browser)
  p_duration      int,      -- JÁ resolvido, > 0 (nunca do browser)
  p_client_id     uuid,     -- conta; NULL para walk-in
  p_client_name   text,
  p_client_email  text,     -- NULL para walk-in
  p_is_encaixe    boolean,
  p_status        text,     -- 'pendente' | 'confirmado'
  p_notes         text,
  p_grid_aligned  boolean
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cfg       public.shop_settings%rowtype;
  v_dow       int := extract(dow from p_day)::int;
  v_janela    jsonb;
  v_open_min  int;
  v_close_min int;
  v_start     int;
  v_end       int;
  v_now       timestamp;
  v_now_min   int;
  v_day_label text;
  v_bad_dur   int;
  v_id        bigint;
begin
  -- 0. guardas de contrato (defesa em profundidade — a chamadora já garante)
  if p_status is null or p_status not in ('pendente', 'confirmado') then
    raise exception 'BAD_STATE' using errcode = 'P0001';
  end if;
  if p_duration is null or p_duration <= 0 then
    raise exception 'BAD_DURATION' using errcode = 'P0001';
  end if;
  if p_service_names is null or cardinality(p_service_names) = 0 then
    raise exception 'SERVICE_INVALID' using errcode = 'P0001';
  end if;

  select * into v_cfg from public.shop_settings where id = 1;
  v_now     := now() at time zone v_cfg.timezone;
  v_now_min := extract(hour from v_now)::int * 60 + extract(minute from v_now)::int;

  v_start := public._hhmm_to_min(p_time);
  if v_start is null then
    raise exception 'BAD_SLOT' using errcode = 'P0001';   -- formato "HH:MM" inválido
  end if;
  v_end := v_start + p_duration;

  -- 1. dia no futuro e dentro da janela de agendamento (fuso da loja)
  if p_day < v_now::date then
    raise exception 'PAST_DAY' using errcode = 'P0001';
  end if;
  if p_day > v_now::date + v_cfg.max_advance_days then
    raise exception 'OUT_OF_WINDOW' using errcode = 'P0001';
  end if;

  -- 2. janela da LOJA no dia (mesma grade que o cliente vê — open_hours[dow]).
  --    dia sem expediente da loja (ex. domingo = null) → BARBER_OFF (é escala).
  v_janela := v_cfg.open_hours -> v_dow::text;
  if v_janela is null or jsonb_typeof(v_janela) <> 'array' then
    raise exception 'BARBER_OFF' using errcode = 'P0001';
  end if;
  v_open_min  := public._hhmm_to_min(v_janela ->> 0);
  v_close_min := public._hhmm_to_min(v_janela ->> 1);

  -- 3. o intervalo inteiro cabe na janela da loja
  if v_start < v_open_min or v_end > v_close_min then
    raise exception 'BAD_SLOT' using errcode = 'P0001';
  end if;

  -- 4. alinhamento de grade — só reschedule normal. Encaixe é off-grid: é o
  --    ponto dele. A grade é ancorada na ABERTURA DA LOJA (igual ao cliente).
  if p_grid_aligned and (v_start - v_open_min) % v_cfg.slot_min <> 0 then
    raise exception 'BAD_SLOT' using errcode = 'P0001';
  end if;

  -- 5. horário que já passou hoje
  if p_day = v_now::date and v_start <= v_now_min then
    raise exception 'PAST_DAY' using errcode = 'P0001';
  end if;

  -- 6. barbeiro existe, atende, e a ESCALA DELE cobre [v_start, v_start+dur]
  --    (mesmo `_barber_covers` do caminho do cliente: hours[dow], ou janela da
  --    loja se hours é null; folga = hours[dow] null → não cobre).
  if not exists (
    select 1 from public.barbers b where b.id = p_barber_id and b.is_barber = true
  ) then
    raise exception 'BARBER_OFF' using errcode = 'P0001';
  end if;
  if not public._barber_covers(
       (select b.hours from public.barbers b where b.id = p_barber_id),
       v_dow, v_start, p_duration
     ) then
    raise exception 'BARBER_OFF' using errcode = 'P0001';
  end if;

  -- 7. lock de AGENDA — serializa concorrentes do mesmo barbeiro/dia.
  --    chave namespaced ('agenda|…') ≠ do lock de CRM ('crm|…') do encaixe.
  perform pg_advisory_xact_lock(
    hashtextextended('agenda|' || p_barber_id::text || '|' || p_day::text, 0)
  );

  -- 8. algum ativo do barbeiro/dia com duration NULL? → NUNCA compara com NULL,
  --    NUNCA fallback. A ST-1b.0 backfillou os ativos; isto é a salvaguarda de
  --    corrida com escrita legada.
  select count(*) into v_bad_dur
  from public.appointments a
  where a.barber_id = p_barber_id
    and a.day = p_day
    and a.status in ('pendente', 'confirmado')
    and a.duration is null;
  if v_bad_dur > 0 then
    raise exception 'OVERLAP_UNCHECKED' using errcode = 'P0001';
  end if;

  -- 9. sobreposição de INTERVALO com agendamento ATIVO do mesmo barbeiro.
  --    O reschedule já cancelou a linha antiga → ela não conta.
  --    is_encaixe NÃO é isento (inclui encaixes já existentes).
  if exists (
    select 1 from public.appointments a
    where a.barber_id = p_barber_id
      and a.day = p_day
      and a.status in ('pendente', 'confirmado')
      and public._hhmm_to_min(a.time) < v_end
      and v_start < public._hhmm_to_min(a.time) + a.duration
  ) then
    raise exception 'SLOT_TAKEN' using errcode = 'P0001';
  end if;

  -- 10. rótulo do dia (servidor — nunca do browser)
  v_day_label := (array['Dom','Seg','Ter','Qua','Qui','Sex','Sáb'])[v_dow + 1]
                 || ' ' || to_char(p_day, 'DD/MM');

  -- 11. insere — duração explícita → a trigger appointments_fill_duration não intervém
  insert into public.appointments
    (client_id, barber_id, services, day, day_label, time, duration,
     status, is_encaixe, client_name, client_email, notes)
  values
    (p_client_id, p_barber_id, p_service_names, p_day, v_day_label, p_time,
     p_duration, p_status, p_is_encaixe, p_client_name, p_client_email, p_notes)
  returning id into v_id;

  return v_id;

exception
  -- SÓ a exclusion constraint appointments_no_overlap (pós-cutover): a corrida
  -- que passou pela checagem manual do passo 9. Sem `when unique_violation`
  -- (o id é GENERATED ALWAYS AS IDENTITY) nem `when others` genérico.
  when exclusion_violation then
    raise exception 'SLOT_TAKEN' using errcode = 'P0001';
end;
$$;

revoke execute on function public._staff_insert_appointment(
  uuid, date, text, text[], int, uuid, text, text, boolean, text, text, boolean
) from public, anon, authenticated, service_role;
