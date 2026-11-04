-- Janela de agendamento do site: por padrão 30 dias à frente; open_until estende a janela (ex.: abrir dezembro inteiro).
-- Dezembro: pagamento antecipado (regra em payment_rules + interruptor payment_settings), reserva de 30 min e cancelamento automático se não pagar.
create table if not exists public.agenda_config (
  id boolean primary key default true check (id),
  horizon_days integer not null default 30 check (horizon_days between 1 and 366),
  open_until date,
  open_label text,
  updated_at timestamptz not null default now()
);
insert into public.agenda_config (id, horizon_days, open_until, open_label) values (true, 30, '2026-12-31', 'dezembro') on conflict (id) do nothing;
alter table public.agenda_config enable row level security;
drop policy if exists agenda_config_public_read on public.agenda_config;
create policy agenda_config_public_read on public.agenda_config for select using (true);
drop policy if exists agenda_config_admin_update on public.agenda_config;
create policy agenda_config_admin_update on public.agenda_config for update
  using (exists (select 1 from public.barbers b where b.id = auth.uid() and b.role = 'admin'))
  with check (exists (select 1 from public.barbers b where b.id = auth.uid() and b.role = 'admin'));
grant select on public.agenda_config to anon, authenticated;
grant update on public.agenda_config to authenticated;

insert into public.payment_rules (label, start_day, end_day)
select 'Agenda de dezembro', '2026-12-01', '2026-12-31'
where not exists (select 1 from public.payment_rules where label = 'Agenda de dezembro');
update public.payment_settings set online_pix_enabled = true, updated_at = now();
