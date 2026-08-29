-- ⚠️  MIGRATION DE CUTOVER — NÃO aplicar junto do lote normal.
--
-- Só rodar quando a agenda do Prime Next estiver no ar e o site LEGADO do
-- CLIENTE não fizer mais INSERT/UPDATE direto em appointments (só via
-- book_appointment / cancel_appointment / reschedule_appointment).
-- Aplicar antes disso QUEBRA o agendamento do cliente no site atual.
--
-- Regra do Codex: a escrita nova da Prime Next só entra em produção JUNTO da
-- proteção definitiva de concorrência.
--
-- Faz:
--   0. PREFLIGHT de serviço legado não resolvido — aborta se houver agendamento
--      ATIVO (pendente/confirmado) com `duration IS NULL` e `services` que não
--      resolvem 100% pelo catálogo atual (por nome). Nada de fallback silencioso
--      de slot_min para agenda ativa: o operador corrige à mão antes;
--   1. backfill de `duration` das linhas antigas + `NOT NULL` (a canônica das
--      linhas NOVAS é a trigger appointments_fill_duration de 20260829000050 —
--      slot_min atual de shop_settings; nenhum default fixo na coluna);
--   2. PREFLIGHT de sobreposição ativa pré-existente;
--   3. EXCLUSION CONSTRAINT por INTERVALO [início, início+duração) por barbeiro
--      — a rede definitiva contra sobreposição. Encaixe NÃO é isento (decisão):
--      overbooking futuro será permissão explícita de staff em fluxo separado;
--   4. remove as POLICIES de escrita direta do CLIENTE em appointments
--      (`clients_insert_own`, `clients_update_own`). Escrita do cliente passa a
--      ser exclusivamente pelas RPCs (SECURITY DEFINER, bypassam RLS).
--
-- Por que policy e não `REVOKE ... FROM authenticated`: `authenticated` inclui
-- os barbeiros/admin, cujo APP DE STAFF legado continua escrevendo direto
-- (barbers_insert_own, admin_update_all, appointments_vendas_*). Dropar só as
-- policies do cliente é cirúrgico: staff intacto.
--
-- `clients_select_own` e `appointment_waitlist` NÃO são tocadas.
--
-- Rollback:
--   alter table public.appointments drop constraint appointments_no_overlap;
--   -- (opcional) alter table public.appointments alter column duration drop not null;
--   create policy clients_insert_own on public.appointments
--     for insert with check (client_id = auth.uid());
--   create policy clients_update_own on public.appointments
--     for update using (client_id = auth.uid()) with check (client_id = auth.uid());
-- Impacto: cliente só escreve agenda via RPC; staff inalterado.

-- 0. PREFLIGHT — serviço legado não resolvido em agenda ATIVA
do $$
declare
  v_bad int;
begin
  -- cardinalidade de a.services vs. quantos desses nomes existem no catálogo atual.
  -- se algum nome sumiu, count < cardinalidade -> registro ativo precisa de correção manual.
  select count(*) into v_bad
  from public.appointments a
  where a.status in ('pendente', 'confirmado')
    and a.duration is null
    and coalesce(cardinality(a.services), 0) <> (
      select count(*) from public.services s where s.name = any(a.services)
    );
  if v_bad > 0 then
    raise exception
      'CUTOVER abortado: % agendamento(s) ATIVO(s) com duration NULL e serviços não resolvíveis pelo catálogo atual (nome sumiu). Corrigir manualmente (setar `duration` ou ajustar `services`) antes do cutover — NÃO usar fallback de slot_min para agenda ativa.',
      v_bad;
  end if;
end $$;

-- extensão para combinar `barber_id WITH =` e range `WITH &&` num exclude
create extension if not exists btree_gist;

-- 1. backfill de duração das linhas antigas (o cliente legado nunca gravava).
--    - totalmente resolvível pelo catálogo -> soma real de duration_min;
--    - não resolvível -> slot_min (só alcançável por histórico INATIVO, pois o
--      preflight §0 já barrou os ativos não resolvíveis; e o inativo não entra
--      na exclusion constraint).
update public.appointments a
set duration = case
  when coalesce(cardinality(a.services), 0) = (
    select count(*) from public.services s where s.name = any(a.services)
  )
    then (select sum(s.duration_min) from public.services s where s.name = any(a.services))
  else (select slot_min from public.shop_settings where id = 1)
end
where a.duration is null;

alter table public.appointments
  alter column duration set not null;

-- 2. PREFLIGHT — sobreposição ativa pré-existente (mesma predicate do exclude)
do $$
declare
  v_over int;
begin
  select count(*) into v_over
  from public.appointments a
  join public.appointments b
    on b.barber_id = a.barber_id
   and b.id <> a.id
   and b.status in ('pendente', 'confirmado')
   and (a.day + a."time"::time) < (b.day + b."time"::time + make_interval(mins => b.duration))
   and (b.day + b."time"::time) < (a.day + a."time"::time + make_interval(mins => a.duration))
  where a.status in ('pendente', 'confirmado');
  if v_over > 0 then
    raise exception
      'CUTOVER abortado: % pares de agendamentos ativos com intervalos sobrepostos para o mesmo barbeiro. Resolver antes de criar a exclusion constraint.',
      v_over / 2;
  end if;
end $$;

-- 3. exclusion constraint — sem sobreposição de intervalo por barbeiro (ativos)
alter table public.appointments
  add constraint appointments_no_overlap
  exclude using gist (
    barber_id with =,
    tsrange(
      (day + "time"::time),
      (day + "time"::time + make_interval(mins => duration)),
      '[)'
    ) with &&
  )
  where (status in ('pendente', 'confirmado'));

-- 4. cliente só escreve agenda via RPC
drop policy if exists clients_insert_own on public.appointments;
drop policy if exists clients_update_own on public.appointments;
