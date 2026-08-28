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
--   1. backfill de `duration` (agendamentos antigos do cliente legado têm
--      duration NULL — a wizard nunca gravava) + default + NOT NULL;
--   2. EXCLUSION CONSTRAINT por INTERVALO [início, início+duração) por
--      barbeiro — a rede definitiva contra sobreposição (não só horário
--      inicial igual). Encaixe NÃO é isento (decisão): overbooking futuro será
--      permissão explícita de staff em fluxo separado;
--   3. remove as POLICIES de escrita direta do CLIENTE em appointments
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
-- Pré-requisito verificado: nenhuma sobreposição ativa pré-existente.
--
-- Rollback:
--   alter table public.appointments drop constraint appointments_no_overlap;
--   -- (opcional) alter table public.appointments alter column duration drop not null;
--   create policy clients_insert_own on public.appointments
--     for insert with check (client_id = auth.uid());
--   create policy clients_update_own on public.appointments
--     for update using (client_id = auth.uid()) with check (client_id = auth.uid());
-- Impacto: cliente só escreve agenda via RPC; staff inalterado.

-- 0. extensão para combinar `barber_id WITH =` e range `WITH &&` num exclude
create extension if not exists btree_gist;

-- 1. backfill de duração (nulls -> soma real dos serviços, fallback slot_min)
update public.appointments a
set duration = greatest(
  coalesce((select sum(s.duration_min) from public.services s
            where s.name = any(a.services)), 0),
  (select slot_min from public.shop_settings where id = 1)
)
where a.duration is null;

alter table public.appointments
  alter column duration set default 45,   -- fallback = slot_min do seed; RPCs sempre gravam a real
  alter column duration set not null;

-- 2. checagem de sobreposição ativa pré-existente (mesma predicate do exclude)
do $$
declare
  v_over int;
begin
  select count(*) into v_over
  from public.appointments a
  join public.appointments b
    on b.barber_id = a.barber_id
   and b.id <> a.id
   and b.status in ('pendente','confirmado')
   and (a.day + a."time"::time) < (b.day + b."time"::time + make_interval(mins => b.duration))
   and (b.day + b."time"::time) < (a.day + a."time"::time + make_interval(mins => a.duration))
  where a.status in ('pendente','confirmado');
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
