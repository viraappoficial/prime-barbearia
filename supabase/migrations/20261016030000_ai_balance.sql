-- Saldo da conta de IA (Anthropic) informado à mão: a Anthropic não expõe o saldo por API.
-- Cada linha é "em tal momento o saldo era X". O saldo atual estimado = último saldo informado - consumo registrado (ai_usage) desde então.
create table if not exists public.ai_balance (
  id bigserial primary key,
  created_at timestamptz not null default now(),
  balance_usd numeric(12,4) not null check (balance_usd >= 0),
  note text,
  created_by uuid default auth.uid()
);
alter table public.ai_balance enable row level security;
drop policy if exists ai_balance_admin_read on public.ai_balance;
create policy ai_balance_admin_read on public.ai_balance for select
  using (exists (select 1 from barbers b where b.id = auth.uid() and b.role = 'admin'));
drop policy if exists ai_balance_admin_insert on public.ai_balance;
create policy ai_balance_admin_insert on public.ai_balance for insert
  with check (exists (select 1 from barbers b where b.id = auth.uid() and b.role = 'admin'));
