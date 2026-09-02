-- Bloqueio de agenda do staff — legado (prime-barbearia), independente do lote de
-- migrations do lab (staff/st-h-gate1, staff/st-1b, staff/st-2, agenda cutover).
-- Não depende de shop_settings/slot_min do lab (essas colunas não existem em
-- produção hoje) nem de barber_role() (idem). Usa só o que já está confirmado
-- rodando em produção nesta sessão: barbers.role e o padrão de policy inline
-- já usado em services/suppliers/bank_accounts.
--
-- 45min = SLOT_MIN, a duração operacional oficial do legado hoje (grade fixa
-- em JS, appointments.duration é NULL pra todo agendamento feito pelo wizard
-- do cliente porque o wizard nunca preenche esse campo).
--
-- Rollback:
--   drop trigger appointments_agenda_block_guard on public.appointments;
--   drop function public._agenda_block_guard();
--   drop function public.agenda_blocked_ranges(date);
--   drop table public.agenda_blocks;
-- Impacto no legado: nenhum em fluxo sem bloqueio nenhum cadastrado — as
-- checagens novas só encontram linha se existir um agenda_blocks colidindo.

-- ══ 1. Tabela ══
create table public.agenda_blocks (
  id          bigint generated always as identity primary key,
  barber_id   uuid not null references public.barbers(id) on delete cascade,
  day         date not null,
  start_time  text not null check (start_time ~ '^[0-2][0-9]:[0-5][0-9]$'),
  end_time    text not null check (end_time ~ '^[0-2][0-9]:[0-5][0-9]$'),
  reason      text check (char_length(reason) <= 140),
  created_by  uuid not null,
  created_at  timestamptz not null default now(),
  constraint agenda_blocks_valid_range check (end_time > start_time),
  constraint agenda_blocks_no_exact_dup unique (barber_id, day, start_time, end_time)
);

comment on table public.agenda_blocks is
  'Janela em que um barbeiro fica indisponível pra novo agendamento (V1: sem repetição semanal, um bloqueio por dia, sem cruzar meia-noite). Sobreposição entre bloqueios do mesmo barbeiro é permitida de propósito — dois bloqueios cobrindo o mesmo horário significam a mesma coisa (indisponível), não há necessidade funcional de impedir, e evita complexidade de concorrência sem ganho real (decisão explícita da V1).';
comment on column public.agenda_blocks.reason is
  'Interno, só staff — nunca exposto ao cliente em nenhuma view/RPC pública.';

alter table public.agenda_blocks enable row level security;

-- created_by/created_at são metadado de auditoria — o browser não decide isso.
-- Mesmo com a policy de INSERT já exigindo created_by = auth.uid(), a trigger
-- força os dois campos incondicionalmente: fecha a hipótese de alguém mandar
-- um created_at forjado (a policy não protege isso, só protege created_by).
create or replace function public._agenda_blocks_set_audit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.created_by := auth.uid();
  new.created_at := now();
  return new;
end;
$$;
revoke execute on function public._agenda_blocks_set_audit()
  from public, anon, authenticated, service_role;

create trigger agenda_blocks_set_audit
  before insert on public.agenda_blocks
  for each row execute function public._agenda_blocks_set_audit();

-- ══ 2. RLS ══
-- SELECT: dono vê os próprios; admin vê todos. Vendas e cliente: nenhuma
-- policy cobre esses papéis -> sem SELECT/INSERT/DELETE, por omissão.
create policy agenda_blocks_barber_select_own on public.agenda_blocks
  for select
  using (barber_id = auth.uid());

create policy agenda_blocks_admin_select_all on public.agenda_blocks
  for select
  using (exists (select 1 from public.barbers b where b.id = auth.uid() and b.role = 'admin'));

-- INSERT: barbeiro só pra si mesmo; admin pra qualquer barbeiro. created_by
-- também trava aqui (defesa em profundidade — a trigger acima é a garantia
-- de verdade, isto é cinto e suspensório).
create policy agenda_blocks_barber_insert_own on public.agenda_blocks
  for insert
  with check (barber_id = auth.uid() and created_by = auth.uid());

create policy agenda_blocks_admin_insert_any on public.agenda_blocks
  for insert
  with check (
    created_by = auth.uid()
    and exists (select 1 from public.barbers b where b.id = auth.uid() and b.role = 'admin')
  );

-- DELETE: barbeiro só o próprio; admin qualquer um; vendas nenhum (D5).
create policy agenda_blocks_barber_delete_own on public.agenda_blocks
  for delete
  using (barber_id = auth.uid());

create policy agenda_blocks_admin_delete_any on public.agenda_blocks
  for delete
  using (exists (select 1 from public.barbers b where b.id = auth.uid() and b.role = 'admin'));

-- sem policy de UPDATE: bloqueio não se edita, só se cria/remove (mais simples,
-- evita reabrir toda a checagem de "mover bloqueio" que não foi pedida na V1).

-- ══ 3. Trigger de aplicação — appointments não pode entrar/ficar ativo dentro
--        de um bloqueio, EXCETO quando a ocupação (barbeiro+dia+hora+duração)
--        já era a mesma antes do UPDATE (isso é o que deixa "Aceitar" livre
--        mesmo se um bloqueio foi criado depois de um pendente já existir) ══
create or replace function public._agenda_block_guard()
returns trigger
language plpgsql
security definer          -- precisa enxergar agenda_blocks mesmo pro cliente,
set search_path = ''      -- que não tem (e não deve ter) SELECT na tabela.
as $$
declare
  v_new_active   boolean;
  v_was_same_occ boolean;
  v_start        int;
  v_end          int;
begin
  v_new_active := new.status in ('pendente', 'confirmado');
  if not v_new_active then
    return new;   -- liberando o horário (cancelado/concluido/nao_compareceu) nunca é barrado
  end if;

  if tg_op = 'UPDATE' then
    -- mesma ocupação de antes (mesmo barbeiro/dia/hora/duração) e já estava ativo?
    -- então não é ocupação nova -- é só o rótulo do status mudando (ex: Aceitar).
    v_was_same_occ :=
      old.status in ('pendente', 'confirmado')
      and old.barber_id is not distinct from new.barber_id
      and old.day       is not distinct from new.day
      and old.time      is not distinct from new.time
      and coalesce(old.duration, 45) = coalesce(new.duration, 45);
    if v_was_same_occ then
      return new;
    end if;
  end if;

  -- 45 = SLOT_MIN, a duração operacional oficial do legado hoje. O wizard do
  -- cliente nunca preenche `duration` (fica NULL) -- é o fallback real, não
  -- um número herdado do lab.
  v_start := public._hhmm_to_min_legacy(new.time);
  if v_start is null then
    return new;   -- horário mal formado não é problema desta trigger; deixa passar
  end if;
  v_end := v_start + coalesce(new.duration, 45);

  if exists (
    select 1
    from public.agenda_blocks bl
    where bl.barber_id = new.barber_id
      and bl.day = new.day
      and public._hhmm_to_min_legacy(bl.start_time) < v_end
      and v_start < public._hhmm_to_min_legacy(bl.end_time)
  ) then
    raise exception 'SLOT_BLOCKED' using errcode = 'P0001';
  end if;

  return new;
end;
$$;
revoke execute on function public._agenda_block_guard()
  from public, anon, authenticated, service_role;

-- helper local -- não reusa nada do lab (_hhmm_to_min de lá não está em produção).
-- Nome com sufixo _legacy de propósito, pra nunca colidir se o lote do lab for
-- aplicado depois (ele cria public._hhmm_to_min, sem sufixo).
create or replace function public._hhmm_to_min_legacy(p text)
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
revoke execute on function public._hhmm_to_min_legacy(text)
  from public, anon, authenticated, service_role;

create trigger appointments_agenda_block_guard
  before insert or update of barber_id, day, time, duration, status
  on public.appointments
  for each row execute function public._agenda_block_guard();

-- ══ 4. Disponibilidade pública mínima pro wizard do cliente ══
-- Devolve só barber_id + intervalo (HH:MM) dos bloqueios de um dia. NUNCA
-- reason, created_by, created_at ou id.
--
-- Decisão consciente de V1: expor `barber_id` junto do intervalo permite, na
-- prática, inferir que aquele barbeiro específico está indisponível naquele
-- horário -- não é anonimato total. Isso é aceitável porque barber_id já é
-- informação pública hoje (aparece na tela de escolha de barbeiro da landing
-- e do wizard). Se no futuro a exigência for privacidade total (nem inferir
-- qual barbeiro está bloqueado), o caminho é trocar esta função por uma que
-- devolve só disponibilidade agregada por horário (`slot, livre`), no estilo
-- de public_day_availability do lab -- sem barber_id nenhum na saída.
create or replace function public.agenda_blocked_ranges(p_day date)
returns table (barber_id uuid, start_time text, end_time text)
language sql
stable
security definer
set search_path = ''
as $$
  select bl.barber_id, bl.start_time, bl.end_time
  from public.agenda_blocks bl
  where bl.day = p_day
$$;
revoke execute on function public.agenda_blocked_ranges(date)
  from public, anon, authenticated, service_role;
grant execute on function public.agenda_blocked_ranges(date) to anon, authenticated;
