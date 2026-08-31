-- ST-1b.5 — protocolo canônico de lock de agenda (corrida cross-surface
-- cliente × staff + inversão de ordem linha↔agenda da ST-1b.4).
--
-- ACHADO 1 — chave advisory divergente.
--   `_insert_appointment` (cliente)        : hashtextextended(barber || '|' || day, 0)
--   `_staff_insert_appointment` (staff)    : hashtextextended('agenda|' || barber || '|' || day, 0)
-- Chaves DIFERENTES → `book_appointment` / `reschedule_appointment` do cliente
-- NÃO serializam contra `staff_book_encaixe` / `staff_reschedule_appointment`.
-- Sem o cutover (exclusion constraint `appointments_no_overlap`), duas escritas
-- concorrentes de superfícies distintas passam pela checagem manual de
-- sobreposição contra o mesmo snapshot e criam agendamentos sobrepostos.
--
-- ACHADO 2 — inversão de ordem de lock (introduzida pela ST-1b.4).
--   ST-1b.4 `staff_reschedule_appointment`: linha (`FOR UPDATE`) → agenda (advisory).
--   `reschedule_appointment` do cliente     : agenda (advisory, no núcleo) → linha (`UPDATE`).
-- Ordens opostas sobre o mesmo `p_id` → ciclo → deadlock (`40P01`).
--
-- CORREÇÃO — protocolo único, aplicado por TODA operação que toca agenda + linha:
--   (a) leitura/autorização MÍNIMA sem lock — só pra descobrir barbeiro/dia-alvo;
--   (b) `_lock_agenda(barbeiro_alvo, dia_alvo)` — advisory da agenda de DESTINO;
--   (c) releitura da linha com `FOR UPDATE` + autorização e estado revalidados
--       SOB o lock;
--   (d) insert/update.
--   NUNCA linha → agenda.
--
-- 1. `_lock_agenda(p_barber_id uuid, p_day date)` — ÚNICA fonte da chave
--    canônica `'agenda|' || barber_id || '|' || day`. `volatile`,
--    `security definer`, `search_path=''`, objetos qualificados, `revoke` de
--    toda role externa, SEM grant. `pg_advisory_xact_lock` é re-entrante por
--    transação → uma RPC que trava a agenda em (b) e chama o núcleo em (d)
--    (que retrava a mesma chave) não conflita consigo mesma (contador, liberado
--    no commit/rollback).
--
-- 2. `_insert_appointment` e `_staff_insert_appointment` — `CREATE OR REPLACE`
--    trocando o `pg_advisory_xact_lock(hashtextextended(...))` inline por
--    `perform public._lock_agenda(p_barber_id, p_day)`. Para o cliente a CHAVE
--    MUDA (passa a ter o prefixo `agenda|`) e alinha com o staff; o resto do
--    corpo é idêntico. Para o staff a chave é a mesma — só centraliza.
--
-- 3. `reschedule_appointment` (cliente) e `staff_reschedule_appointment` (staff)
--    — `CREATE OR REPLACE` para o protocolo (a)-(d). `book_appointment` e
--    `staff_book_encaixe` NÃO mudam: só inserem → o lock canônico via o núcleo
--    basta (não há linha pré-existente a travar).
--
-- 4. `SECURITY DEFINER`, `search_path=''`, objetos qualificados, `plpgsql`
--    estático preservados. `CREATE OR REPLACE` preserva os grants
--    (`book_appointment` / `reschedule_appointment` / `staff_reschedule_appointment`
--    → `authenticated`; núcleos e `_lock_agenda` → só owner) — reafirmados
--    abaixo como documentação executável idempotente. Mensagens `P0001`
--    inalteradas — nenhum código de erro novo.
--
-- Ordem global de locks após esta migration (sem ciclo):
--   agenda(dest)  →  [linha FOR UPDATE]  →  agenda(dest) re-entrante (núcleo)
--   staff_book_encaixe: crm|tel → crm|nom → agenda (núcleo)  — não toca linha.
--   accept/start/undo_start/no_show/cancel (staff, ST-1b.4): só linha FOR UPDATE
--     (não tocam agenda) — nada inverte contra elas.
--
-- Rollback (helper por último):
--   -- reschedule_appointment / staff_reschedule_appointment: CREATE OR REPLACE
--   --   de volta ao corpo de 20260829000400 / 20260831000400.
--   -- _insert_appointment / _staff_insert_appointment: CREATE OR REPLACE de
--   --   volta ao corpo de 20260829000200 / 20260831000100 (lock inline).
--   -- drop function public._lock_agenda(uuid, date);
-- Impacto no legado: nenhum. O `#barberApp` segue no UPDATE/INSERT direto;
-- nenhuma função legada chama estes objetos.

-- ══ 1. helper canônico de lock de agenda ══════════════════════════════════════
create or replace function public._lock_agenda(p_barber_id uuid, p_day date)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  -- CHAVE CANÔNICA DA AGENDA — não replicar em outro lugar; chamar este helper.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('agenda|' || p_barber_id::text || '|' || p_day::text, 0)
  );
end;
$$;

revoke execute on function public._lock_agenda(uuid, date)
  from public, anon, authenticated, service_role;

-- ══ 2a. núcleo do CLIENTE — usa o helper canônico (chave passa a ter 'agenda|') ══
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

  -- 5. serializa concorrentes que disputam o mesmo barbeiro/dia — CHAVE CANÔNICA
  --    (helper único, compartilhado com `_staff_insert_appointment`).
  perform public._lock_agenda(p_barber_id, p_day);

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

-- ══ 2b. núcleo do STAFF — usa o helper canônico (chave inalterada) ════════════
create or replace function public._staff_insert_appointment(
  p_barber_id     uuid,
  p_day           date,
  p_time          text,
  p_service_names text[],
  p_duration      int,
  p_client_id     uuid,
  p_client_name   text,
  p_client_email  text,
  p_is_encaixe    boolean,
  p_status        text,
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

  -- 7. lock de AGENDA — CHAVE CANÔNICA (helper único, compartilhado com
  --    `_insert_appointment`). Namespace 'agenda|…' ≠ 'crm|…' do encaixe.
  perform public._lock_agenda(p_barber_id, p_day);

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

-- ══ 3a. reschedule do CLIENTE — protocolo (a)-(d) ════════════════════════════
create or replace function public.reschedule_appointment(
  p_id          bigint,
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
  v_client uuid := auth.uid();
  v_ocid   uuid;
  v_old    public.appointments%rowtype;
  v_new_id bigint;
  v_lbl    text;
  v_name   text;
begin
  -- (a) autorização MÍNIMA sem lock. O destino (barbeiro/dia) vem dos
  --     parâmetros — nada a descobrir na linha; só confirmar que é o dono.
  if v_client is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = 'P0001';
  end if;
  select client_id into v_ocid from public.appointments where id = p_id;
  if not found or v_ocid is distinct from v_client then
    raise exception 'NOT_FOUND' using errcode = 'P0001';   -- não vaza posse alheia
  end if;

  -- (b) trava a AGENDA DE DESTINO (chave canônica) ANTES de qualquer lock de
  --     linha. `_insert_appointment` retrava a mesma chave (re-entrante).
  perform public._lock_agenda(p_barber_id, p_day);

  -- (c) relê a linha FOR UPDATE e revalida posse + estado SOB o lock.
  select * into v_old from public.appointments where id = p_id for update;
  if not found or v_old.client_id is distinct from v_client then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
  if v_old.status not in ('pendente', 'confirmado') then
    raise exception 'NOT_RESCHEDULABLE' using errcode = 'P0001';
  end if;

  -- (d) cria o novo primeiro — se falhar (inclusive SLOT_TAKEN) → ROLLBACK, o
  --     antigo continua ativo. Só então cancela o antigo.
  v_new_id := public._insert_appointment(v_client, p_barber_id, p_day, p_time, p_service_ids);
  update public.appointments set status = 'cancelado' where id = p_id;

  select a.client_name, a.day_label into v_name, v_lbl
  from public.appointments a where a.id = v_new_id;
  v_name := coalesce(v_name, 'Cliente');

  -- notifica o barbeiro do NOVO horário
  insert into public.notifications
    (for_role, recipient_barber_id, recipient_client_id, type, appt_id, text)
  values
    ('barber', p_barber_id, null, 'novo', v_new_id,
     v_name || ' remarcou para ' || v_lbl || ' às ' || p_time);

  -- se trocou de barbeiro, avisa o antigo que o slot liberou
  if v_old.barber_id is distinct from p_barber_id then
    insert into public.notifications
      (for_role, recipient_barber_id, recipient_client_id, type, appt_id, text)
    values
      ('barber', v_old.barber_id, null, 'cancelado', p_id,
       v_name || ' remarcou e liberou ' || v_old.day_label || ' às ' || v_old.time);
  end if;

  return v_new_id;
end;
$$;

-- ══ 3b. reschedule do STAFF — protocolo (a)-(d) (re-substitui a ST-1b.4) ══════
create or replace function public.staff_reschedule_appointment(
  p_id   bigint,
  p_day  date,
  p_time text
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid        uuid := auth.uid();
  v_role       text;
  v_bid        uuid;
  v_old        public.appointments%rowtype;
  v_dur        int;
  v_resolvidos int;
  v_new_id     bigint;
  v_new        public.appointments%rowtype;
begin
  -- (a) autorização MÍNIMA sem lock — só o suficiente pra descobrir a
  --     agenda-alvo (mesmo barbeiro da linha; o dia é p_day). Posse REAL
  --     revalidada em (c) por `_staff_appt_for_write_locked`.
  if v_uid is null then
    raise exception 'NOT_AUTH' using errcode = 'P0001';
  end if;
  v_role := public.barber_role();
  if v_role is null then
    raise exception 'NOT_STAFF' using errcode = 'P0001';
  end if;
  select barber_id into v_bid from public.appointments where id = p_id;
  if not found then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
  if not (v_bid = v_uid or v_role in ('admin', 'vendas')) then
    raise exception 'NOT_FOUND' using errcode = 'P0001';   -- não vaza posse alheia
  end if;

  -- (b) trava a AGENDA DE DESTINO (chave canônica) ANTES de qualquer lock de
  --     linha. staff_reschedule NÃO troca de barbeiro → destino = (v_bid, p_day).
  --     `_staff_insert_appointment` retrava a mesma chave (re-entrante).
  perform public._lock_agenda(v_bid, p_day);

  -- (c) relê a linha FOR UPDATE + revalida auth/papel/posse/estado SOB o lock.
  v_old := public._staff_appt_for_write_locked(p_id, true);
  if v_old.barber_id is distinct from v_bid then
    -- inalcançável: barber_id é imutável (fora do guard de staff da ST-H e do
    -- grant de coluna de `authenticated`). Defesa: aborta seguro, SEM tomar
    -- outro advisory lock — jamais reintroduz inversão linha→agenda.
    raise exception 'NOT_RESCHEDULABLE' using errcode = 'P0001';
  end if;
  if v_old.status not in ('pendente', 'confirmado') or v_old.iniciado_em is not null then
    raise exception 'NOT_RESCHEDULABLE' using errcode = 'P0001';
  end if;

  -- (d) duração da linha antiga — nunca NULL na sobreposição, nunca fallback
  if v_old.duration is not null then
    v_dur := v_old.duration;
  else
    select count(*) into v_resolvidos
    from public.services s where s.name = any(v_old.services);
    if coalesce(cardinality(v_old.services), 0) = v_resolvidos and v_resolvidos > 0 then
      select sum(s.duration_min) into v_dur
      from public.services s where s.name = any(v_old.services);
    else
      raise exception 'OVERLAP_UNCHECKED' using errcode = 'P0001';
    end if;
  end if;

  -- cancela o antigo AGORA (dentro da transação) — sai da checagem do núcleo
  update public.appointments set status = 'cancelado' where id = p_id;

  -- cria o novo — tudo herdado de v_old; browser só mandou p_id/p_day/p_time
  v_new_id := public._staff_insert_appointment(
    p_barber_id     => v_old.barber_id,          -- mesmo barbeiro (D-1b-2)
    p_day           => p_day,
    p_time          => p_time,
    p_service_names => v_old.services,            -- nomes da linha antiga
    p_duration      => v_dur,
    p_client_id     => v_old.client_id,
    p_client_name   => v_old.client_name,
    p_client_email  => v_old.client_email,
    p_is_encaixe    => v_old.is_encaixe,          -- encaixe remarcado continua encaixe
    p_status        => v_old.status,              -- preserva (D-1b-3)
    p_notes         => v_old.notes,
    p_grid_aligned  => not v_old.is_encaixe       -- reschedule normal = grade; encaixe = off-grid
  );

  -- notifica o cliente — só se conta (walk-in não tem)
  if v_old.client_id is not null then
    select * into v_new from public.appointments where id = v_new_id;
    insert into public.notifications
      (for_role, recipient_client_id, type, appt_id, text)
    values
      ('client', v_old.client_id, 'remarcado', v_new_id,
       'Seu horário de ' || v_old.day_label || ' às ' || v_old.time
       || ' foi remarcado para ' || v_new.day_label || ' às ' || p_time || '.');
  end if;

  return v_new_id;
end;
$$;

-- ══ 4. grants — inalterados; reafirmados como documentação executável ════════
revoke execute on function public._lock_agenda(uuid, date)
  from public, anon, authenticated, service_role;
revoke execute on function public._insert_appointment(uuid, uuid, date, text, bigint[])
  from public, anon, authenticated, service_role;
revoke execute on function public._staff_insert_appointment(
  uuid, date, text, text[], int, uuid, text, text, boolean, text, text, boolean
) from public, anon, authenticated, service_role;
revoke execute on function public.reschedule_appointment(bigint, uuid, date, text, bigint[])
  from public, anon, authenticated, service_role;
revoke execute on function public.staff_reschedule_appointment(bigint, date, text)
  from public, anon, authenticated, service_role;

grant execute on function public.reschedule_appointment(bigint, uuid, date, text, bigint[])
  to authenticated;
grant execute on function public.staff_reschedule_appointment(bigint, date, text)
  to authenticated;
