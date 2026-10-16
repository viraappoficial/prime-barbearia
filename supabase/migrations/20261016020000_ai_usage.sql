-- Consumo da IA do WhatsApp: uma linha por resposta e por modelo (tokens, chamadas à API, custo estimado em US$).
-- Quem grava é o servidor do assistente (service role); só admin lê (tela Gestão > IA).
create table if not exists public.ai_usage (
  id bigserial primary key,
  created_at timestamptz not null default now(),
  chat_id text,
  model text not null,
  input_tokens integer not null default 0,
  output_tokens integer not null default 0,
  calls integer not null default 1,
  cost_usd numeric(12,6) not null default 0
);
create index if not exists ai_usage_created_at_idx on public.ai_usage (created_at desc);
alter table public.ai_usage enable row level security;
drop policy if exists ai_usage_admin_read on public.ai_usage;
create policy ai_usage_admin_read on public.ai_usage for select
  using (exists (select 1 from barbers b where b.id = auth.uid() and b.role = 'admin'));
