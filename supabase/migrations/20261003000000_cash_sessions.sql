-- Caixa por SESSÃO — legado (prime-barbearia). Independente do lote do lab/Prime Next:
-- não usa barber_role(), shop_settings, nem as funções staff_caixa_* / _caixa_* do lab.
-- Nomes novos e distintos: tabela cash_sessions, cash_config, funções cash_session_* e _cs_*.
--
-- Regras (decididas com o dono, ver conversa):
--   • um caixa aberto por vez (índice único parcial);
--   • abrir, fechar, sangria e suprimento exigem CONFIRMAÇÃO DE ADMIN, e isso é
--     garantido no banco: as RPCs só rodam se auth.uid() for admin. O app executa
--     essas RPCs com a sessão do admin que digitou a senha (porta de confirmação),
--     passando em p_operator quem está de fato operando o caixa (vendas ou admin);
--   • quem fecha é quem abriu; admin pode fechar o caixa de qualquer um
--     (senão uma sessão esquecida trava todas as vendas);
--   • todo pagamento (sale_payments) e todo movimento de dinheiro do caixa
--     (sangria origem='caixa', suprimento) é carimbado com a sessão aberta e com
--     quem registrou. O carimbo vem de TRIGGER, ignora o que o cliente mandar;
--   • a trava "sem caixa aberto não registra venda" fica DESLIGADA nesta migration
--     (cash_config.enforce_open_session = false). Liga-se depois, com uma linha de
--     SQL, quando a tela do caixa estiver no ar. Desliga-se do mesmo jeito.
--
-- Dinheiro esperado do fechamento:
--   abertura contada + pagamentos em dinheiro da sessão + suprimentos da sessão
--   − sangrias da sessão que saem do caixa (a sangria de fechamento NÃO entra na conta:
--   ela é a retirada do que foi contado, depois de comparar).
-- Cartão, Pix e a prazo aparecem no relatório, mas não entram na conta de falta/sobra.
--
-- Fechamento: a pessoa conta o dinheiro, diz quanto FICA no caixa pro dia seguinte
-- (o fundo) e o restante vira uma sangria de fechamento (cofre ou banco). A abertura
-- seguinte é conferida contra esse valor que ficou.
--
-- Tudo aditivo: não altera nenhuma coluna existente, nenhuma policy existente.
-- cash_closures continua sendo gravada no fechamento (uma linha por sessão) para
-- manter o bloqueio de edição de despesas em dinheiro nos dias fechados.
--
-- Rollback (nesta ordem):
--   drop trigger cash_sangrias_cs_stamp on public.cash_sangrias;
--   drop trigger cash_supplies_cs_stamp on public.cash_supplies;
--   drop trigger sale_payments_cs_stamp on public.sale_payments;
--   drop function public.cash_session_current(), public.cash_session_open(uuid, numeric, text),
--     public.cash_session_close(uuid, numeric, numeric, text, bigint, text),
--     public.cash_session_sangria(uuid, numeric, text, bigint, text),
--     public.cash_session_suprimento(uuid, numeric, text, bigint, text),
--     public.cash_session_report(bigint), public.cash_session_list(integer),
--     public._cs_stamp_payment(), public._cs_stamp_sangria(), public._cs_stamp_supply(),
--     public._cs_open_or_raise(boolean), public._cs_expected(bigint),
--     public._cs_check_operator(uuid, uuid), public._cs_require_admin(), public._cs_role(uuid);
--   alter table public.cash_closures drop column cash_session_id;
--   alter table public.cash_supplies drop column cash_session_id, drop column operator_id;
--   alter table public.cash_sangrias drop column cash_session_id, drop column operator_id, drop column is_closing;
--   alter table public.sale_payments drop column cash_session_id, drop column operator_id;
--   drop table public.cash_sessions; drop table public.cash_config;
-- Impacto no legado com a trava desligada: nenhum fluxo muda; os registros novos só
-- ganham o carimbo (nulo enquanto não houver sessão aberta).

-- ══ 1. Configuração da trava ══
create table public.cash_config (
  id                   integer primary key check (id = 1),
  enforce_open_session boolean not null default false
);
insert into public.cash_config (id) values (1);
alter table public.cash_config enable row level security;
revoke all on public.cash_config from public, anon, authenticated;

-- ══ 2. Sessões ══
-- opened_by/closed_by/confirmed_by são uuid SEM foreign key de propósito: é registro
-- de auditoria e não pode impedir "remover barbeiro" nem mudar se a conta sair.
create table public.cash_sessions (
  id                    bigint generated always as identity primary key,
  opened_by             uuid not null,
  opened_confirmed_by   uuid not null,
  opened_at             timestamptz not null default now(),
  opening_amount        numeric(12,2) not null check (opening_amount >= 0),
  expected_opening      numeric(12,2) check (expected_opening >= 0),
  opening_difference    numeric(12,2),
  opening_note          text check (char_length(opening_note) <= 300),
  closed_by             uuid,
  closed_confirmed_by   uuid,
  closed_at             timestamptz,
  expected_cash         numeric(12,2),
  counted_cash          numeric(12,2) check (counted_cash >= 0),
  difference            numeric(12,2),
  carry_amount          numeric(12,2) check (carry_amount >= 0),
  withdrawn_amount      numeric(12,2) check (withdrawn_amount >= 0),
  close_destino         text check (close_destino in ('cofre', 'banco')),
  close_bank_account_id bigint references public.bank_accounts(id),
  close_note            text check (char_length(close_note) <= 300),
  constraint cash_sessions_closed_all_or_none check (
    (closed_at is null and closed_by is null and closed_confirmed_by is null
       and expected_cash is null and counted_cash is null and difference is null
       and carry_amount is null and withdrawn_amount is null)
    or
    (closed_at is not null and closed_by is not null and closed_confirmed_by is not null
       and expected_cash is not null and counted_cash is not null and difference is not null
       and carry_amount is not null and withdrawn_amount is not null)
  ),
  constraint cash_sessions_carry_withdrawn check (
    carry_amount is null or (carry_amount <= counted_cash and withdrawn_amount = counted_cash - carry_amount)
  )
);
-- um único caixa aberto por vez
create unique index cash_sessions_one_open on public.cash_sessions ((true)) where closed_at is null;
create index cash_sessions_closed_at_idx on public.cash_sessions (closed_at desc);

alter table public.cash_sessions enable row level security;
revoke all on public.cash_sessions from public, anon, authenticated;
grant select on public.cash_sessions to authenticated;
-- só admin lê direto; vendas e demais leem pelas RPCs. Sem policy de INSERT/UPDATE/DELETE:
-- só as funções SECURITY DEFINER escrevem, então a sessão não é adulterável pelo cliente.
create policy cash_sessions_admin_select on public.cash_sessions
  for select
  using (exists (select 1 from public.barbers b where b.id = auth.uid() and b.role = 'admin'));

-- ══ 3. Colunas novas nas tabelas existentes (todas anuláveis; histórico fica nulo) ══
alter table public.sale_payments
  add column if not exists cash_session_id bigint references public.cash_sessions(id),
  add column if not exists operator_id uuid;
alter table public.cash_sangrias
  add column if not exists cash_session_id bigint references public.cash_sessions(id),
  add column if not exists operator_id uuid,
  add column if not exists is_closing boolean not null default false;
alter table public.cash_supplies
  add column if not exists cash_session_id bigint references public.cash_sessions(id),
  add column if not exists operator_id uuid;
alter table public.cash_closures
  add column if not exists cash_session_id bigint references public.cash_sessions(id);

create index if not exists sale_payments_cash_session_idx on public.sale_payments (cash_session_id);
create index if not exists cash_sangrias_cash_session_idx on public.cash_sangrias (cash_session_id);
create index if not exists cash_supplies_cash_session_idx on public.cash_supplies (cash_session_id);

-- ══ 4. Helpers internos (sem EXECUTE pra ninguém de fora) ══
create or replace function public._cs_role(p_uid uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select b.role from public.barbers b where b.id = p_uid
$$;

-- a confirmação de admin é checada AQUI, no banco: auth.uid() precisa ser admin.
create or replace function public._cs_require_admin()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null or coalesce(public._cs_role(v_uid), '') <> 'admin' then
    raise exception 'NOT_ADMIN' using errcode = 'P0001';
  end if;
  return v_uid;
end;
$$;

-- quem opera uma sessão é quem abriu; admin opera qualquer uma
create or replace function public._cs_check_operator(p_operator uuid, p_opened_by uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_role text := public._cs_role(p_operator);
begin
  if p_operator is null or v_role is null then
    raise exception 'BAD_OPERATOR' using errcode = 'P0001';
  end if;
  if p_operator <> p_opened_by and v_role <> 'admin' then
    raise exception 'NOT_SESSION_OWNER' using errcode = 'P0001';
  end if;
end;
$$;

create or replace function public._cs_expected(p_session bigint)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select round(
    s.opening_amount
    + coalesce((select sum(p.value) from public.sale_payments p
                where p.cash_session_id = s.id and p.method = 'dinheiro'), 0)
    + coalesce((select sum(u.value) from public.cash_supplies u
                where u.cash_session_id = s.id), 0)
    - coalesce((select sum(g.value) from public.cash_sangrias g
                where g.cash_session_id = s.id and g.origem = 'caixa' and not g.is_closing), 0)
  , 2)
  from public.cash_sessions s
  where s.id = p_session
$$;

-- sessão aberta (ou nulo). Com a trava ligada: sem sessão = erro; sessão aberta num dia
-- anterior = erro (fecha antes de seguir). p_allow_stale é só pro fluxo de fechamento.
-- FOR SHARE: todo registro de dinheiro segura um lock de leitura na sessão até commitar,
-- e o fechamento pega FOR UPDATE. Assim o fechamento espera os registros em andamento
-- terminarem (entram no esperado) e um registro que chega durante o fechamento espera
-- e então encontra a sessão já fechada. Sem isso, uma venda no instante do fechamento
-- ficaria na sessão sem entrar na conta de falta/sobra.
create or replace function public._cs_open_or_raise(p_allow_stale boolean)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id      bigint;
  v_opened  timestamptz;
  v_enforce boolean;
begin
  select s.id, s.opened_at into v_id, v_opened
  from public.cash_sessions s where s.closed_at is null
  for share;
  select c.enforce_open_session into v_enforce from public.cash_config c where c.id = 1;
  if coalesce(v_enforce, false) then
    if v_id is null then
      raise exception 'NO_OPEN_CASH_SESSION' using errcode = 'P0001';
    end if;
    if not p_allow_stale
       and (v_opened at time zone 'America/Sao_Paulo')::date < (now() at time zone 'America/Sao_Paulo')::date then
      raise exception 'CASH_SESSION_STALE' using errcode = 'P0001';
    end if;
  end if;
  return v_id;
end;
$$;

-- ══ 5. Triggers de carimbo — o cliente não decide sessão nem operador ══
create or replace function public._cs_stamp_payment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.cash_session_id := public._cs_open_or_raise(false);
  new.operator_id := auth.uid();
  return new;
end;
$$;

create or replace function public._cs_stamp_sangria()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_closing boolean := coalesce(current_setting('app.cash_closing', true), '') = 'on';
begin
  if new.origem <> 'caixa' then
    -- cofre -> banco não mexe no dinheiro do caixa: sem sessão, sem trava
    new.cash_session_id := null;
    new.is_closing := false;
    new.operator_id := auth.uid();
    return new;
  end if;
  new.cash_session_id := public._cs_open_or_raise(v_closing);
  new.is_closing := v_closing;
  new.operator_id := coalesce(nullif(current_setting('app.cash_operator', true), '')::uuid, auth.uid());
  return new;
end;
$$;

create or replace function public._cs_stamp_supply()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.cash_session_id := public._cs_open_or_raise(false);
  new.operator_id := coalesce(nullif(current_setting('app.cash_operator', true), '')::uuid, auth.uid());
  return new;
end;
$$;

create trigger sale_payments_cs_stamp
  before insert on public.sale_payments
  for each row execute function public._cs_stamp_payment();
create trigger cash_sangrias_cs_stamp
  before insert on public.cash_sangrias
  for each row execute function public._cs_stamp_sangria();
create trigger cash_supplies_cs_stamp
  before insert on public.cash_supplies
  for each row execute function public._cs_stamp_supply();

-- ══ 6. RPCs ══
-- estado atual: qualquer pessoa da equipe consulta (a tela precisa saber se há caixa aberto)
create or replace function public.cash_session_current()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  s         public.cash_sessions%rowtype;
  v_enforce boolean;
  v_carry   numeric;
begin
  if v_uid is null or public._cs_role(v_uid) is null then
    raise exception 'NOT_STAFF' using errcode = 'P0001';
  end if;
  select * into s from public.cash_sessions where closed_at is null;
  select c.enforce_open_session into v_enforce from public.cash_config c where c.id = 1;
  select x.carry_amount into v_carry
  from public.cash_sessions x where x.closed_at is not null
  order by x.closed_at desc, x.id desc limit 1;
  return jsonb_build_object(
    'enforced', coalesce(v_enforce, false),
    'open', s.id is not null,
    'stale', s.id is not null
             and (s.opened_at at time zone 'America/Sao_Paulo')::date < (now() at time zone 'America/Sao_Paulo')::date,
    'session', case when s.id is null then null else jsonb_build_object(
        'id', s.id,
        'opened_by', s.opened_by,
        'opened_by_name', (select b.name from public.barbers b where b.id = s.opened_by),
        'opened_at', s.opened_at,
        'opening_amount', s.opening_amount) end,
    'suggested_opening', v_carry
  );
end;
$$;

create or replace function public.cash_session_open(p_operator uuid, p_amount numeric, p_note text default null)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin uuid;
  v_prev  numeric;
  v_amt   numeric;
  v_id    bigint;
begin
  v_admin := public._cs_require_admin();
  if p_operator is null or coalesce(public._cs_role(p_operator), '') not in ('vendas', 'admin') then
    raise exception 'BAD_OPERATOR' using errcode = 'P0001';
  end if;
  if p_amount is null or p_amount < 0 then
    raise exception 'BAD_AMOUNT' using errcode = 'P0001';
  end if;
  v_amt := round(p_amount, 2);
  select x.carry_amount into v_prev
  from public.cash_sessions x where x.closed_at is not null
  order by x.closed_at desc, x.id desc limit 1;
  begin
    insert into public.cash_sessions
      (opened_by, opened_confirmed_by, opening_amount, expected_opening, opening_difference, opening_note)
    values
      (p_operator, v_admin, v_amt, v_prev,
       case when v_prev is null then null else v_amt - v_prev end,
       nullif(trim(p_note), ''))
    returning id into v_id;
  exception when unique_violation then
    raise exception 'SESSION_ALREADY_OPEN' using errcode = 'P0001';
  end;
  return v_id;
end;
$$;

create or replace function public.cash_session_sangria(
  p_operator uuid, p_value numeric, p_destino text,
  p_bank_account_id bigint default null, p_note text default null
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin uuid;
  s       public.cash_sessions%rowtype;
  v_id    bigint;
begin
  v_admin := public._cs_require_admin();
  select * into s from public.cash_sessions where closed_at is null;
  if not found then
    raise exception 'NO_OPEN_SESSION' using errcode = 'P0001';
  end if;
  perform public._cs_check_operator(p_operator, s.opened_by);
  if p_value is null or round(p_value, 2) <= 0 then
    raise exception 'BAD_AMOUNT' using errcode = 'P0001';
  end if;
  if p_destino is null or p_destino not in ('cofre', 'banco') then
    raise exception 'BAD_DESTINO' using errcode = 'P0001';
  end if;
  if p_destino = 'banco' and not exists (select 1 from public.bank_accounts a where a.id = p_bank_account_id) then
    raise exception 'BAD_BANK' using errcode = 'P0001';
  end if;
  perform set_config('app.cash_operator', p_operator::text, true);
  insert into public.cash_sangrias (value, origem, destino, bank_account_id, admin_id, barber_id, note)
  values (round(p_value, 2), 'caixa', p_destino,
          case when p_destino = 'banco' then p_bank_account_id end,
          v_admin, p_operator, nullif(trim(p_note), ''))
  returning id into v_id;
  perform set_config('app.cash_operator', '', true);
  return v_id;
end;
$$;

create or replace function public.cash_session_suprimento(
  p_operator uuid, p_value numeric, p_origem text,
  p_bank_account_id bigint default null, p_note text default null
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin uuid;
  s       public.cash_sessions%rowtype;
  v_id    bigint;
begin
  v_admin := public._cs_require_admin();
  select * into s from public.cash_sessions where closed_at is null;
  if not found then
    raise exception 'NO_OPEN_SESSION' using errcode = 'P0001';
  end if;
  perform public._cs_check_operator(p_operator, s.opened_by);
  if p_value is null or round(p_value, 2) <= 0 then
    raise exception 'BAD_AMOUNT' using errcode = 'P0001';
  end if;
  if p_origem is null or p_origem not in ('cofre', 'banco', 'outro') then
    raise exception 'BAD_ORIGEM' using errcode = 'P0001';
  end if;
  if p_origem = 'banco' and not exists (select 1 from public.bank_accounts a where a.id = p_bank_account_id) then
    raise exception 'BAD_BANK' using errcode = 'P0001';
  end if;
  perform set_config('app.cash_operator', p_operator::text, true);
  insert into public.cash_supplies (value, origem, bank_account_id, admin_id, barber_id, note)
  values (round(p_value, 2), p_origem,
          case when p_origem = 'banco' then p_bank_account_id end,
          v_admin, p_operator, nullif(trim(p_note), ''))
  returning id into v_id;
  perform set_config('app.cash_operator', '', true);
  return v_id;
end;
$$;

create or replace function public.cash_session_close(
  p_operator uuid, p_counted numeric, p_carry numeric,
  p_destino text default null, p_bank_account_id bigint default null, p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin     uuid;
  s           public.cash_sessions%rowtype;
  v_counted   numeric;
  v_carry     numeric;
  v_expected  numeric;
  v_withdrawn numeric;
  v_diff      numeric;
begin
  v_admin := public._cs_require_admin();
  select * into s from public.cash_sessions where closed_at is null for update;
  if not found then
    raise exception 'NO_OPEN_SESSION' using errcode = 'P0001';
  end if;
  perform public._cs_check_operator(p_operator, s.opened_by);
  if p_counted is null or p_counted < 0 then
    raise exception 'BAD_AMOUNT' using errcode = 'P0001';
  end if;
  v_counted := round(p_counted, 2);
  if p_carry is null or p_carry < 0 or round(p_carry, 2) > v_counted then
    raise exception 'BAD_CARRY' using errcode = 'P0001';
  end if;
  v_carry := round(p_carry, 2);
  v_withdrawn := v_counted - v_carry;
  if v_withdrawn > 0 then
    if p_destino is null or p_destino not in ('cofre', 'banco') then
      raise exception 'BAD_DESTINO' using errcode = 'P0001';
    end if;
    if p_destino = 'banco' and not exists (select 1 from public.bank_accounts a where a.id = p_bank_account_id) then
      raise exception 'BAD_BANK' using errcode = 'P0001';
    end if;
  end if;

  -- esperado calculado ANTES da sangria de fechamento (ela é a retirada do contado)
  v_expected := public._cs_expected(s.id);
  v_diff := v_counted - v_expected;

  if v_withdrawn > 0 then
    perform set_config('app.cash_operator', p_operator::text, true);
    perform set_config('app.cash_closing', 'on', true);
    insert into public.cash_sangrias (value, origem, destino, bank_account_id, admin_id, barber_id, note)
    values (v_withdrawn, 'caixa', p_destino,
            case when p_destino = 'banco' then p_bank_account_id end,
            v_admin, p_operator,
            'Fechamento de caixa #' || s.id || coalesce(' — ' || nullif(trim(p_note), ''), ''));
    perform set_config('app.cash_closing', '', true);
    perform set_config('app.cash_operator', '', true);
  end if;

  update public.cash_sessions set
    closed_by = p_operator, closed_confirmed_by = v_admin, closed_at = now(),
    expected_cash = v_expected, counted_cash = v_counted, difference = v_diff,
    carry_amount = v_carry, withdrawn_amount = v_withdrawn,
    close_destino = case when v_withdrawn > 0 then p_destino end,
    close_bank_account_id = case when v_withdrawn > 0 and p_destino = 'banco' then p_bank_account_id end,
    close_note = nullif(trim(p_note), '')
  where id = s.id;

  insert into public.cash_closures
    (period_from, period_to, expected_value, counted_value, difference, admin_id, cash_session_id)
  values
    ((s.opened_at at time zone 'America/Sao_Paulo')::date,
     (now() at time zone 'America/Sao_Paulo')::date,
     v_expected, v_counted, v_diff, v_admin, s.id);

  return jsonb_build_object(
    'id', s.id, 'expected', v_expected, 'counted', v_counted, 'difference', v_diff,
    'carry', v_carry, 'withdrawn', v_withdrawn);
end;
$$;

-- relatório de uma sessão: admin vê qualquer uma; quem abriu vê a própria
create or replace function public.cash_session_report(p_session bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  s     public.cash_sessions%rowtype;
begin
  if v_uid is null or public._cs_role(v_uid) is null then
    raise exception 'NOT_STAFF' using errcode = 'P0001';
  end if;
  select * into s from public.cash_sessions where id = p_session;
  if not found then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
  if public._cs_role(v_uid) <> 'admin' and s.opened_by <> v_uid then
    raise exception 'NOT_ALLOWED' using errcode = 'P0001';
  end if;

  return jsonb_build_object(
    'session', to_jsonb(s) || jsonb_build_object(
        'opened_by_name', (select b.name from public.barbers b where b.id = s.opened_by),
        'opened_confirmed_by_name', (select b.name from public.barbers b where b.id = s.opened_confirmed_by),
        'closed_by_name', (select b.name from public.barbers b where b.id = s.closed_by),
        'closed_confirmed_by_name', (select b.name from public.barbers b where b.id = s.closed_confirmed_by)),
    'expected_cash', case when s.closed_at is null then public._cs_expected(s.id) else s.expected_cash end,
    'by_method', (
      select coalesce(jsonb_object_agg(m.method, m.total), '{}'::jsonb)
      from (select p.method, sum(p.value) as total
            from public.sale_payments p where p.cash_session_id = s.id group by p.method) m),
    'by_barber', (
      select coalesce(jsonb_agg(jsonb_build_object('barber_id', x.barber_id, 'name', b.name, 'total', x.total)
                                order by x.total desc), '[]'::jsonb)
      from (select p.barber_id, sum(p.value) as total
            from public.sale_payments p
            where p.cash_session_id = s.id and p.method <> 'a_prazo' group by p.barber_id) x
      left join public.barbers b on b.id = x.barber_id),
    'by_operator', (
      select coalesce(jsonb_agg(jsonb_build_object('operator_id', x.operator_id, 'name', b.name, 'total', x.total)
                                order by x.total desc), '[]'::jsonb)
      from (select p.operator_id, sum(p.value) as total
            from public.sale_payments p
            where p.cash_session_id = s.id and p.method <> 'a_prazo' group by p.operator_id) x
      left join public.barbers b on b.id = x.operator_id),
    'sangrias', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', g.id, 'value', g.value, 'destino', g.destino, 'note', g.note,
               'is_closing', g.is_closing, 'operator_id', g.operator_id, 'created_at', g.created_at)
             order by g.created_at), '[]'::jsonb)
      from public.cash_sangrias g where g.cash_session_id = s.id),
    'suprimentos', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', u.id, 'value', u.value, 'origem', u.origem, 'note', u.note,
               'operator_id', u.operator_id, 'created_at', u.created_at)
             order by u.created_at), '[]'::jsonb)
      from public.cash_supplies u where u.cash_session_id = s.id),
    'notas', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'nota_id', n.nota_id, 'at', n.at, 'paid', n.paid, 'methods', n.methods,
               'client', (select min(sl.client_name) from public.sales sl where sl.nota_id = n.nota_id),
               'items', (select string_agg(sl.service || case when coalesce(sl.qty, 1) > 1 then ' x' || sl.qty else '' end,
                                           ' + ' order by sl.id)
                         from public.sales sl where sl.nota_id = n.nota_id))
             order by n.at), '[]'::jsonb)
      from (select p.nota_id, min(p.created_at) as at, sum(p.value) as paid,
                   string_agg(distinct p.method, ', ') as methods
            from public.sale_payments p where p.cash_session_id = s.id group by p.nota_id) n)
  );
end;
$$;

create or replace function public.cash_session_list(p_limit integer default 20)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_role text;
begin
  v_role := public._cs_role(v_uid);
  if v_uid is null or v_role is null or v_role not in ('admin', 'vendas') then
    raise exception 'NOT_ALLOWED' using errcode = 'P0001';
  end if;
  return (
    select coalesce(jsonb_agg(to_jsonb(t) order by t.id desc), '[]'::jsonb)
    from (
      select s.id, s.opened_by, (select b.name from public.barbers b where b.id = s.opened_by) as opened_by_name,
             s.opened_at, s.opening_amount, s.opening_difference,
             s.closed_by, (select b.name from public.barbers b where b.id = s.closed_by) as closed_by_name,
             s.closed_at, s.expected_cash, s.counted_cash, s.difference, s.carry_amount, s.withdrawn_amount
      from public.cash_sessions s
      where v_role = 'admin' or s.opened_by = v_uid
      order by s.id desc
      limit greatest(1, least(coalesce(p_limit, 20), 100))
    ) t
  );
end;
$$;

-- ══ 7. Permissões: helpers e triggers fechados; só as RPCs públicas abrem pra 'authenticated' ══
revoke execute on function public._cs_role(uuid) from public, anon, authenticated, service_role;
revoke execute on function public._cs_require_admin() from public, anon, authenticated, service_role;
revoke execute on function public._cs_check_operator(uuid, uuid) from public, anon, authenticated, service_role;
revoke execute on function public._cs_expected(bigint) from public, anon, authenticated, service_role;
revoke execute on function public._cs_open_or_raise(boolean) from public, anon, authenticated, service_role;
revoke execute on function public._cs_stamp_payment() from public, anon, authenticated, service_role;
revoke execute on function public._cs_stamp_sangria() from public, anon, authenticated, service_role;
revoke execute on function public._cs_stamp_supply() from public, anon, authenticated, service_role;

revoke execute on function public.cash_session_current() from public, anon, authenticated, service_role;
revoke execute on function public.cash_session_open(uuid, numeric, text) from public, anon, authenticated, service_role;
revoke execute on function public.cash_session_close(uuid, numeric, numeric, text, bigint, text) from public, anon, authenticated, service_role;
revoke execute on function public.cash_session_sangria(uuid, numeric, text, bigint, text) from public, anon, authenticated, service_role;
revoke execute on function public.cash_session_suprimento(uuid, numeric, text, bigint, text) from public, anon, authenticated, service_role;
revoke execute on function public.cash_session_report(bigint) from public, anon, authenticated, service_role;
revoke execute on function public.cash_session_list(integer) from public, anon, authenticated, service_role;

grant execute on function public.cash_session_current() to authenticated;
grant execute on function public.cash_session_open(uuid, numeric, text) to authenticated;
grant execute on function public.cash_session_close(uuid, numeric, numeric, text, bigint, text) to authenticated;
grant execute on function public.cash_session_sangria(uuid, numeric, text, bigint, text) to authenticated;
grant execute on function public.cash_session_suprimento(uuid, numeric, text, bigint, text) to authenticated;
grant execute on function public.cash_session_report(bigint) to authenticated;
grant execute on function public.cash_session_list(integer) to authenticated;
