-- ST-1b.4 — trava de linha nas RPCs de escrita de staff (corrida de concorrência).
--
-- ACHADO. `_staff_appt_for_write(p_id, …)` (ST-H.4) lê a linha SEM lock
-- (`stable`, `select … where id = p_id`), e só DEPOIS a RPC chamadora atualiza
-- o status. Duas requisições simultâneas sobre o MESMO `p_id` capturam o mesmo
-- snapshot MVCC (READ COMMITTED), ambas passam pela checagem de status contra o
-- valor VELHO, e o `update … where id = p_id` da 2ª — quando destrava após o
-- commit da 1ª — re-casa o `where` (só `id = p_id`) e reaplica a escrita sem
-- reavaliar o status. Efeitos observados:
--   - `staff_reschedule_appointment`: o antigo é cancelado 1×, mas o núcleo roda
--     2× → DOIS novos agendamentos ativos a partir de UMA origem (quando os
--     alvos são slots livres distintos — o advisory lock `agenda|…` serializa os
--     inserts mas não os rejeita se não se sobrepõem; dias distintos nem
--     serializam);
--   - `staff_accept_appointment` / `staff_cancel_appointment`: 2ª chamada emite
--     uma SEGUNDA notificação ao cliente;
--   - `staff_start_appointment`: 2ª chamada sobrescreve `iniciado_em` em vez de
--     `ALREADY_STARTED`;
--   - `staff_undo_start`: 2ª chamada "desfaz" de novo sem `BAD_TRANSITION`.
-- A matriz da ST-1b (R15/E19) já cobre DUAS LINHAS distintas disputando UM slot;
-- não cobria N chamadas sobre a MESMA linha. Corrigido aqui + na matriz.
--
-- CORREÇÃO. Novo helper interno `_staff_appt_for_write_locked(p_id, p_allow_vendas)`
-- idêntico ao `_staff_appt_for_write` porém:
--   - `volatile` (trava linha — é efeito colateral; `stable` seria mentira);
--   - `select … where id = p_id FOR UPDATE` — a 2ª sessão BLOQUEIA aqui até o
--     commit da 1ª e então relê a versão nova da linha;
--   - revalida `auth.uid()` (NOT_AUTH) e `barber_role()` (NOT_STAFF) antes do
--     lock, e a POSSE (dono / admin / vendas-quando-permitido) contra a linha
--     JÁ TRAVADA — `NOT_FOUND` para linha alheia (não vaza posse), igual ao
--     helper velho;
--   - `security definer`, `set search_path = ''`, objetos `public.`/`auth.`
--     qualificados, plpgsql estático (sem SQL dinâmico);
--   - `revoke execute` de todas as roles externas, SEM grant — só o owner
--     (postgres) chama, de dentro das 6 RPCs abaixo.
-- Cada RPC chamadora passa a: (1) pegar a linha travada pelo helper; (2)
-- revalidar o status/`iniciado_em` contra ESSA linha; (3) escrever. Como o
-- estado lido já é o pós-commit da 1ª sessão, a 2ª cai no erro de domínio certo
-- (`NOT_RESCHEDULABLE` / `BAD_TRANSITION` / `ALREADY_STARTED`) — todos P0001 já
-- no mapa estrito da UI. Nenhum código de erro novo.
--
-- As 6 RPCs são recriadas por `CREATE OR REPLACE` — corpo idêntico exceto a
-- troca `_staff_appt_for_write` → `_staff_appt_for_write_locked`. `CREATE OR
-- REPLACE` PRESERVA os grants (`grant execute … to authenticated`) e as
-- mensagens `raise … using errcode = 'P0001'`. `_staff_appt_for_write` (stable,
-- sem lock) é mantido — inerte, sem grant externo, sem chamador — só para o
-- bloco de rollback da ST-H.4 seguir válido; um `COMMENT ON FUNCTION` marca que
-- foi substituído.
--
-- Ordem de locks (sem inversão): a linha de `appointments` é travada ANTES de
-- qualquer advisory lock. Só `staff_reschedule_appointment` toma advisory
-- (`agenda|…` via `_staff_insert_appointment`); as outras 5 não tomam nenhum.
-- Não há ciclo → sem deadlock. Se uma 2ª sessão esperar além do
-- `statement_timeout` do PostgREST (8s), recebe `57014` → a UI cai no genérico
-- (`traduzErroStaff*` → `desconhecido`), sem vazar texto cru; as transações
-- reais duram milissegundos.
--
-- Rollback (helper por último — as 6 RPCs dependem dele):
--   create or replace function public.staff_accept_appointment(bigint) …      -- volta a chamar _staff_appt_for_write(p_id, true)
--   create or replace function public.staff_start_appointment(bigint) …       -- idem
--   create or replace function public.staff_undo_start(bigint) …             -- idem
--   create or replace function public.staff_no_show(bigint) …                -- idem
--   create or replace function public.staff_cancel_appointment(bigint, text) … -- _staff_appt_for_write(p_id, false)
--   create or replace function public.staff_reschedule_appointment(bigint, date, text) … -- _staff_appt_for_write(p_id, true)
--   drop function public._staff_appt_for_write_locked(bigint, boolean);
--   comment on function public._staff_appt_for_write(bigint, boolean) is null;
-- (os corpos "de volta" são os das migrations 20260830000300 / 20260831000200.)
-- Impacto no legado: nenhum. O `#barberApp` segue no UPDATE/INSERT direto (o
-- guard da ST-H libera as colunas operacionais); nenhuma função legada chama
-- estes helpers.

-- ── helper interno TRAVADO: resolve appt + valida posse/papel SOB o lock ─────
create or replace function public._staff_appt_for_write_locked(p_id bigint, p_allow_vendas boolean)
returns public.appointments
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_role text;
  v_appt public.appointments%rowtype;
begin
  if v_uid is null then
    raise exception 'NOT_AUTH' using errcode = 'P0001';
  end if;

  v_role := public.barber_role();
  if v_role is null then
    raise exception 'NOT_STAFF' using errcode = 'P0001';
  end if;

  -- FOR UPDATE: uma 2ª sessão sobre o mesmo p_id bloqueia AQUI até o commit da
  -- 1ª, e então relê a linha na versão nova (o `where id = p_id` re-casa).
  select * into v_appt from public.appointments where id = p_id for update;
  if not found then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;

  -- posse checada contra a linha JÁ TRAVADA. dono sempre; admin sempre; vendas
  -- só quando a operação permite. linha alheia → NOT_FOUND (não vaza posse).
  if not (
       v_appt.barber_id = v_uid
    or v_role = 'admin'
    or (p_allow_vendas and v_role = 'vendas')
  ) then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;

  return v_appt;
end;
$$;

revoke execute on function public._staff_appt_for_write_locked(bigint, boolean)
  from public, anon, authenticated, service_role;

comment on function public._staff_appt_for_write(bigint, boolean) is
  'SUBSTITUÍDO pela ST-1b.4 por _staff_appt_for_write_locked (SELECT … FOR UPDATE). '
  'Mantido inerte (sem grant externo, sem chamador) só para o rollback da ST-H.4. '
  'NÃO usar em caminho de escrita — não trava a linha.';

-- ── staff_accept_appointment — pendente → confirmado + notif ────────────────
create or replace function public.staff_accept_appointment(p_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_appt public.appointments%rowtype := public._staff_appt_for_write_locked(p_id, true);
begin
  if v_appt.status <> 'pendente' then
    raise exception 'BAD_TRANSITION' using errcode = 'P0001';
  end if;

  update public.appointments set status = 'confirmado' where id = p_id;

  if v_appt.client_id is not null then
    insert into public.notifications
      (for_role, recipient_client_id, type, appt_id, text)
    values
      ('client', v_appt.client_id, 'confirmado', p_id,
       'Seu horário de ' || v_appt.day_label || ' às ' || v_appt.time
       || ' foi confirmado pelo barbeiro. Te espero!');
  end if;
end;
$$;

-- ── staff_start_appointment — confirmado & iniciado_em null → seta iniciado_em ─
create or replace function public.staff_start_appointment(p_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_appt public.appointments%rowtype := public._staff_appt_for_write_locked(p_id, true);
begin
  if v_appt.status <> 'confirmado' then
    raise exception 'BAD_TRANSITION' using errcode = 'P0001';
  end if;
  if v_appt.iniciado_em is not null then
    raise exception 'ALREADY_STARTED' using errcode = 'P0001';
  end if;

  update public.appointments set iniciado_em = now() where id = p_id;
end;
$$;

-- ── staff_undo_start — janela de graça: iniciado_em → null ──────────────────
create or replace function public.staff_undo_start(p_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_appt public.appointments%rowtype := public._staff_appt_for_write_locked(p_id, true);
begin
  if v_appt.iniciado_em is null then
    raise exception 'BAD_TRANSITION' using errcode = 'P0001';  -- nada pra desfazer
  end if;

  update public.appointments set iniciado_em = null where id = p_id;
end;
$$;

-- ── staff_no_show — {pendente,confirmado} → nao_compareceu (sem notif) ──────
create or replace function public.staff_no_show(p_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_appt public.appointments%rowtype := public._staff_appt_for_write_locked(p_id, true);
begin
  if v_appt.status not in ('pendente', 'confirmado') then
    raise exception 'BAD_TRANSITION' using errcode = 'P0001';
  end if;

  update public.appointments set status = 'nao_compareceu' where id = p_id;
  -- sem notificação: não faz sentido avisar quem não compareceu (legado idem).
end;
$$;

-- ── staff_cancel_appointment — {pendente,confirmado} → cancelado + notif ────
create or replace function public.staff_cancel_appointment(p_id bigint, p_motivo text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_appt   public.appointments%rowtype := public._staff_appt_for_write_locked(p_id, false);  -- vendas NÃO (D4)
  v_motivo text := nullif(btrim(coalesce(p_motivo, '')), '');
begin
  if v_appt.status not in ('pendente', 'confirmado') then
    raise exception 'BAD_TRANSITION' using errcode = 'P0001';
  end if;

  update public.appointments set status = 'cancelado' where id = p_id;

  if v_appt.client_id is not null then
    insert into public.notifications
      (for_role, recipient_client_id, type, appt_id, text)
    values
      ('client', v_appt.client_id, 'cancelado-barbeiro', p_id,
       'Seu horário de ' || v_appt.day_label || ' às ' || v_appt.time
       || ' foi cancelado pelo barbeiro.'
       || case when v_motivo is not null then ' Motivo: ' || v_motivo || '.' else '' end
       || ' Toque aqui para reagendar.');
  end if;
end;
$$;

-- ── staff_reschedule_appointment — novo id + cancela o antigo, atômico ──────
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
  v_old        public.appointments%rowtype;
  v_dur        int;
  v_resolvidos int;
  v_new_id     bigint;
  v_new        public.appointments%rowtype;
begin
  -- 1. posse/papel + linha TRAVADA (vendas incluído — D-1b-1). A 2ª sessão
  --    sobre o mesmo p_id bloqueia aqui e relê o estado pós-commit da 1ª.
  v_old := public._staff_appt_for_write_locked(p_id, true);

  -- 2. só remarca agendamento ATIVO e não iniciado — reavaliado sob o lock:
  --    se a 1ª sessão já cancelou p_id, esta cai aqui → NOT_RESCHEDULABLE.
  if v_old.status not in ('pendente', 'confirmado') or v_old.iniciado_em is not null then
    raise exception 'NOT_RESCHEDULABLE' using errcode = 'P0001';
  end if;

  -- 3. duração da linha antiga — nunca NULL na sobreposição, nunca fallback
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

  -- 4. cancela o antigo AGORA (dentro da transação) — sai da checagem do núcleo
  update public.appointments set status = 'cancelado' where id = p_id;

  -- 5. cria o novo — tudo herdado de v_old; browser só mandou p_id/p_day/p_time
  v_new_id := public._staff_insert_appointment(
    p_barber_id     => v_old.barber_id,          -- mesmo barbeiro (D-1b-2)
    p_day           => p_day,
    p_time          => p_time,
    p_service_names => v_old.services,            -- nomes da linha antiga
    p_duration      => v_dur,                     -- passo 3
    p_client_id     => v_old.client_id,
    p_client_name   => v_old.client_name,
    p_client_email  => v_old.client_email,
    p_is_encaixe    => v_old.is_encaixe,          -- encaixe remarcado continua encaixe
    p_status        => v_old.status,              -- preserva (D-1b-3)
    p_notes         => v_old.notes,
    p_grid_aligned  => not v_old.is_encaixe       -- reschedule normal = grade; encaixe = off-grid
  );

  -- 6. notifica o cliente — só se conta (walk-in não tem)
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

-- ── grants: inalterados. CREATE OR REPLACE preserva os grants existentes.
--    Reafirmados aqui como documentação executável (idempotente):
revoke execute on function public._staff_appt_for_write(bigint, boolean)
  from public, anon, authenticated, service_role;
revoke execute on function public.staff_accept_appointment(bigint)
  from public, anon, authenticated, service_role;
revoke execute on function public.staff_start_appointment(bigint)
  from public, anon, authenticated, service_role;
revoke execute on function public.staff_undo_start(bigint)
  from public, anon, authenticated, service_role;
revoke execute on function public.staff_no_show(bigint)
  from public, anon, authenticated, service_role;
revoke execute on function public.staff_cancel_appointment(bigint, text)
  from public, anon, authenticated, service_role;
revoke execute on function public.staff_reschedule_appointment(bigint, date, text)
  from public, anon, authenticated, service_role;

grant execute on function public.staff_accept_appointment(bigint)       to authenticated;
grant execute on function public.staff_start_appointment(bigint)        to authenticated;
grant execute on function public.staff_undo_start(bigint)               to authenticated;
grant execute on function public.staff_no_show(bigint)                  to authenticated;
grant execute on function public.staff_cancel_appointment(bigint, text) to authenticated;
grant execute on function public.staff_reschedule_appointment(bigint, date, text) to authenticated;
