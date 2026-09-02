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
-- PREFLIGHT (rodar no lab ANTES de aplicar esta migration, dado real):
--   select count(*) from public.appointments
--   where status in ('pendente','confirmado')
--     and (time !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' or coalesce(duration,45) <= 0);
-- Se o resultado for > 0: essas linhas ativas passam a barrar (fail-closed,
-- INVALID_TIME/INVALID_DURATION) qualquer UPDATE futuro nas colunas observadas
-- pela trigger (inclusive Aceitar/Remarcar), até serem corrigidas manualmente.
-- Decisão deliberada — a alternativa (deixar passar com dado ruim) permitiria
-- a um agendamento com horário/duração inválidos contornar o bloqueio, porque
-- o intervalo dele nunca seria calculável pra comparar com agenda_blocks.
--
-- Rollback:
--   drop trigger appointments_agenda_block_guard on public.appointments;
--   drop function public._agenda_block_guard();
--   drop function public._hhmm_to_min_legacy(text);
--   drop function public.agenda_blocked_ranges(date);
--   drop table public.agenda_blocks;
-- Impacto no legado: nenhum em fluxo sem bloqueio nenhum cadastrado — as
-- checagens novas só encontram linha se existir um agenda_blocks colidindo,
-- exceto o preflight acima (dado malformado pré-existente já ativo).

-- ══ 1. Tabela ══
create table public.agenda_blocks (
  id          bigint generated always as identity primary key,
  barber_id   uuid not null references public.barbers(id) on delete cascade,
  day         date not null,
  start_time  text not null check (start_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
  end_time    text not null check (end_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
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

-- ══ 2. Grants explícitos na TABELA — não presume default privileges do Supabase.
-- Alguns projetos Supabase configuram ALTER DEFAULT PRIVILEGES no schema public
-- concedendo acesso amplo a anon/authenticated em toda tabela nova; aqui isso é
-- revogado e reconcedido de forma explícita, pra não depender de configuração
-- implícita do projeto:
--   anon: nada (nem SELECT) — cliente nunca lê agenda_blocks direto, só via
--         agenda_blocked_ranges() (SECURITY DEFINER, abaixo);
--   authenticated: SELECT/INSERT/DELETE — a RLS decide quais LINHAS, o grant
--         só abre a OPERAÇÃO; sem UPDATE (bloqueio não se edita nesta V1).
-- Sequência da identity (agenda_blocks_id_seq): NENHUM grant separado é
-- necessário. `generated always as identity` (diferente do `serial` clássico)
-- não exige USAGE na sequência subjacente pra quem já tem INSERT na tabela —
-- é o mesmo padrão já em produção em suppliers/bank_accounts/chart_of_accounts
-- (nenhuma dessas migrations concede nada na sequência, e o cadastro funciona).
revoke all on public.agenda_blocks from public, anon, authenticated;
grant select, insert, delete on public.agenda_blocks to authenticated;

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

-- ══ 3. RLS ══
-- "Própria agenda" NÃO pode ser só `barber_id = auth.uid()` — uma conta
-- role='vendas' também tem linha em `barbers` (é staff), então se ela tentasse
-- inserir/ler/remover um agenda_blocks com barber_id = o próprio auth.uid()
-- (ou seja, "bloqueio da agenda dela mesma"), passaria pela checagem sem essa
-- segunda condição, violando D5 (vendas não pode ter acesso nenhum). A policy
-- de "própria agenda" agora EXIGE role='barbeiro' no ator, não só a igualdade
-- de id. Admin continua coberto pelas policies globais separadas (admin_*),
-- que não dependem de barber_id = auth.uid() — cobre bloquear a agenda de
-- QUALQUER profissional, inclusive a própria.
create policy agenda_blocks_barber_select_own on public.agenda_blocks
  for select
  using (
    barber_id = auth.uid()
    and exists (select 1 from public.barbers b where b.id = auth.uid() and b.role = 'barbeiro')
  );

create policy agenda_blocks_admin_select_all on public.agenda_blocks
  for select
  using (exists (select 1 from public.barbers b where b.id = auth.uid() and b.role = 'admin'));

-- INSERT: barbeiro (role='barbeiro') só pra si mesmo; admin pra qualquer
-- barbeiro. created_by também trava aqui (defesa em profundidade — a trigger
-- de auditoria acima é a garantia de verdade, isto é cinto e suspensório).
create policy agenda_blocks_barber_insert_own on public.agenda_blocks
  for insert
  with check (
    barber_id = auth.uid()
    and created_by = auth.uid()
    and exists (select 1 from public.barbers b where b.id = auth.uid() and b.role = 'barbeiro')
  );

create policy agenda_blocks_admin_insert_any on public.agenda_blocks
  for insert
  with check (
    created_by = auth.uid()
    and exists (select 1 from public.barbers b where b.id = auth.uid() and b.role = 'admin')
  );

-- DELETE: barbeiro (role='barbeiro') só o próprio; admin qualquer um; vendas
-- nenhum (D5) -- fecha por omissão, sem policy dedicada pra esse papel.
create policy agenda_blocks_barber_delete_own on public.agenda_blocks
  for delete
  using (
    barber_id = auth.uid()
    and exists (select 1 from public.barbers b where b.id = auth.uid() and b.role = 'barbeiro')
  );

create policy agenda_blocks_admin_delete_any on public.agenda_blocks
  for delete
  using (exists (select 1 from public.barbers b where b.id = auth.uid() and b.role = 'admin'));

-- sem policy de UPDATE: bloqueio não se edita, só se cria/remove (mais simples,
-- evita reabrir toda a checagem de "mover bloqueio" que não foi pedida na V1).

-- ══ 4. Trigger de aplicação — appointments não pode entrar/ficar ativo dentro
--        de um bloqueio, EXCETO quando a ocupação (barbeiro+dia+hora+duração)
--        já era a mesma antes do UPDATE (isso é o que deixa "Aceitar" livre
--        mesmo se um bloqueio foi criado depois de um pendente já existir).
--        Fail-closed: horário mal formado ou duração <= 0 num agendamento
--        ATIVO é rejeitado, nunca deixado passar sem checar (ver PREFLIGHT
--        no topo do arquivo) ══
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
  v_duration     int;
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

  -- horário mal formado num agendamento ativo NUNCA passa sem checar -- fail
  -- closed. Deixar passar (`return new`) seria abrir uma brecha: um horário
  -- que não dá pra converter em minutos nunca bateria contra nenhum bloqueio,
  -- então qualquer `time` inválido contornaria a trava por completo.
  v_start := public._hhmm_to_min_legacy(new.time);
  if v_start is null then
    raise exception 'INVALID_TIME' using errcode = 'P0001';
  end if;

  -- 45 = SLOT_MIN, a duração operacional oficial do legado hoje. O wizard do
  -- cliente nunca preenche `duration` (fica NULL) -- é o fallback real, não
  -- um número herdado do lab. Duração <= 0 também é fail-closed: um intervalo
  -- vazio ou invertido [v_start, v_end) nunca cruza NADA na comparação de
  -- sobreposição, então duration=0 (ou negativo) seria uma forma de o
  -- intervalo "desaparecer" e contornar qualquer bloqueio.
  v_duration := coalesce(new.duration, 45);
  if v_duration <= 0 then
    raise exception 'INVALID_DURATION' using errcode = 'P0001';
  end if;
  v_end := v_start + v_duration;

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
-- aplicado depois (ele cria public._hhmm_to_min, sem sufixo). Faixa de hora
-- 00-23 (não 00-29) -- regex antigo aceitava "25:00" como válido.
create or replace function public._hhmm_to_min_legacy(p text)
returns integer
language sql
immutable
set search_path = ''
as $$
  select case
    when p ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
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

-- ══ 5. Disponibilidade pública mínima pro wizard do cliente ══
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
