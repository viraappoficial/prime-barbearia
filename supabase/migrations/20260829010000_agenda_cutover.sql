-- ⚠️  MIGRATION DE CUTOVER — NÃO aplicar junto do lote normal.
--
-- Só rodar quando a agenda do Prime Next estiver no ar e o site LEGADO do
-- CLIENTE não fizer mais INSERT/UPDATE direto em appointments (só via
-- book_appointment / cancel_appointment / reschedule_appointment).
-- Aplicar antes disso QUEBRA o agendamento do cliente no site atual.
--
-- Faz duas coisas:
--   1. índice único parcial — rede de segurança definitiva contra dois
--      agendamentos ATIVOS no mesmo (barber_id, day, time). Encaixe NÃO é
--      isento (decisão): overbooking futuro será permissão explícita de staff
--      em fluxo separado.
--   2. remove as POLICIES de escrita direta do CLIENTE em appointments
--      (`clients_insert_own`, `clients_update_own`). A escrita do cliente passa
--      a ser exclusivamente pelas RPCs (SECURITY DEFINER, bypassam RLS).
--
-- Por que policy e não `REVOKE ... FROM authenticated`: `authenticated` inclui
-- os barbeiros/admin, cujo APP DE STAFF legado continua escrevendo direto em
-- appointments (barbers_insert_own, admin_update_all, appointments_vendas_*).
-- Revogar o grant quebraria o staff. Dropar só as policies do cliente é
-- cirúrgico: staff intacto, cliente só via RPC.
--
-- `clients_select_own` NÃO é tocada — a Área do Cliente precisa ler.
-- `appointment_waitlist` NÃO é tocada aqui — waitlist com escrita é Fatia 3.
--
-- Pré-requisito verificado: não pode haver duplicata ativa pré-existente.
--
-- Rollback:
--   create policy clients_insert_own on public.appointments
--     for insert with check (client_id = auth.uid());
--   create policy clients_update_own on public.appointments
--     for update using (client_id = auth.uid()) with check (client_id = auth.uid());
--   drop index if exists public.appointments_slot_ativo_uq;
-- Impacto: cliente só escreve agenda via RPC; staff inalterado.

-- 1. checagem de duplicatas ativas pré-existentes
do $$
declare
  v_dups int;
begin
  select count(*) into v_dups from (
    select 1 from public.appointments
    where status in ('pendente', 'confirmado', 'concluido')
    group by barber_id, day, "time"
    having count(*) > 1
  ) d;
  if v_dups > 0 then
    raise exception
      'CUTOVER abortado: % combinações (barber_id, day, time) têm mais de um agendamento ativo. Resolver antes de criar o índice único.',
      v_dups;
  end if;
end $$;

-- 2. índice único parcial
create unique index appointments_slot_ativo_uq
  on public.appointments (barber_id, day, "time")
  where status in ('pendente', 'confirmado', 'concluido');

-- 3. cliente só escreve agenda via RPC
drop policy if exists clients_insert_own on public.appointments;
drop policy if exists clients_update_own on public.appointments;
