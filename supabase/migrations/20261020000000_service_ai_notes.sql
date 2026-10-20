-- Notas dos serviços só pra IA do WhatsApp. Fica numa tabela separada (e não numa coluna de services) porque services tem leitura pública:
-- aqui só admin lê/escreve; o servidor do bot lê com a chave de serviço.
create table if not exists public.service_ai_notes (
  service_id bigint primary key references public.services(id) on delete cascade,
  notes text not null default '',
  updated_at timestamptz not null default now()
);
alter table public.service_ai_notes enable row level security;
drop policy if exists service_ai_notes_admin_select on public.service_ai_notes;
create policy service_ai_notes_admin_select on public.service_ai_notes for select
  using (exists (select 1 from barbers b where b.id = auth.uid() and b.role = 'admin'));
drop policy if exists service_ai_notes_admin_insert on public.service_ai_notes;
create policy service_ai_notes_admin_insert on public.service_ai_notes for insert
  with check (exists (select 1 from barbers b where b.id = auth.uid() and b.role = 'admin'));
drop policy if exists service_ai_notes_admin_update on public.service_ai_notes;
create policy service_ai_notes_admin_update on public.service_ai_notes for update
  using (exists (select 1 from barbers b where b.id = auth.uid() and b.role = 'admin'))
  with check (exists (select 1 from barbers b where b.id = auth.uid() and b.role = 'admin'));
drop policy if exists service_ai_notes_admin_delete on public.service_ai_notes;
create policy service_ai_notes_admin_delete on public.service_ai_notes for delete
  using (exists (select 1 from barbers b where b.id = auth.uid() and b.role = 'admin'));
