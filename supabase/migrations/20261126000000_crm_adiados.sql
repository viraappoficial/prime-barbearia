-- CRM: cliente adiado. A equipe tira o cliente da lista (já falou pelo particular, vai agendar, está viajando…) e escolhe o dia
-- em que ele volta sozinho para o CRM. Chave = telefone do cliente (ou "n:nome" quando não há telefone), igual ao CRM.
-- Rollback: drop table public.crm_adiados;
create table if not exists public.crm_adiados (
  id bigint generated always as identity primary key,
  chave text not null,
  phone text,
  client_name text not null,
  ate date not null,
  motivo text,
  barber_id uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists crm_adiados_chave_uq on public.crm_adiados (chave);
alter table public.crm_adiados enable row level security;

drop policy if exists crm_adiados_staff_read on public.crm_adiados;
create policy crm_adiados_staff_read on public.crm_adiados for select to authenticated
  using (exists (select 1 from public.barbers b where b.id = auth.uid()));
drop policy if exists crm_adiados_staff_insert on public.crm_adiados;
create policy crm_adiados_staff_insert on public.crm_adiados for insert to authenticated
  with check (barber_id = auth.uid() and exists (select 1 from public.barbers b where b.id = auth.uid()));
drop policy if exists crm_adiados_staff_update on public.crm_adiados;
create policy crm_adiados_staff_update on public.crm_adiados for update to authenticated
  using (exists (select 1 from public.barbers b where b.id = auth.uid()))
  with check (exists (select 1 from public.barbers b where b.id = auth.uid()));
drop policy if exists crm_adiados_staff_delete on public.crm_adiados;
create policy crm_adiados_staff_delete on public.crm_adiados for delete to authenticated
  using (exists (select 1 from public.barbers b where b.id = auth.uid()));
