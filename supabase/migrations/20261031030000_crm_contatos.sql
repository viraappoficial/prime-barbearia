-- Registro de quem foi chamado pelo CRM (botão de WhatsApp): quem chamou, quando e qual mensagem.
-- Rollback: drop table public.crm_contatos;
create table if not exists public.crm_contatos (
  id bigint generated always as identity primary key,
  phone text not null,
  client_name text not null,
  barber_id uuid not null default auth.uid(),
  modelo text,
  created_at timestamptz not null default now()
);
create index if not exists crm_contatos_phone_idx on public.crm_contatos (phone, created_at desc);
alter table public.crm_contatos enable row level security;
drop policy if exists crm_contatos_staff_read on public.crm_contatos;
create policy crm_contatos_staff_read on public.crm_contatos for select to authenticated
  using (exists (select 1 from public.barbers b where b.id = auth.uid()));
drop policy if exists crm_contatos_staff_insert on public.crm_contatos;
create policy crm_contatos_staff_insert on public.crm_contatos for insert to authenticated
  with check (barber_id = auth.uid() and exists (select 1 from public.barbers b where b.id = auth.uid()));
grant select, insert on public.crm_contatos to authenticated;
