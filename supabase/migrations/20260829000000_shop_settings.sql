-- Configuração canônica da loja para a agenda.
--
-- Hoje a janela de funcionamento, a duração do slot e o fuso são implícitos no
-- frontend (HORARIOS, SLOT_MIN em domain/agenda.ts; fuso do navegador). A
-- partir da fatia de escrita de agenda, as RPCs precisam da MESMA regra, no
-- servidor. Esta tabela é a fonte única.
--
-- Configuração ativa única e inequívoca: linha única forçada por
-- `check (id = 1)` + PK. Sem policy de DELETE em lugar nenhum -> ninguém
-- apaga a config; as RPCs leem sempre `where id = 1`, sem escolha ambígua.
-- Escrita só admin.
--
-- Rollback: drop table public.shop_settings;
-- Impacto: nenhum no legado (não lê esta tabela). Base para as RPCs.

create table public.shop_settings (
  id               smallint primary key default 1 check (id = 1),
  slot_min         integer not null check (slot_min between 5 and 240),
  open_hours       jsonb not null,   -- { "0": null, "1": ["09:00","20:00"], ... "6": ["09:00","18:00"] }  (0 = domingo)
  max_advance_days integer not null default 10 check (max_advance_days between 1 and 90),
  timezone         text not null default 'America/Sao_Paulo',
  updated_at       timestamptz not null default now()
);

comment on table public.shop_settings is
  'Configuração única da loja (id=1) para a agenda. Escrita só admin, sem delete.';

alter table public.shop_settings enable row level security;

-- leitura liberada: a disponibilidade pública precisa da grade (sem PII aqui).
create policy shop_settings_public_read on public.shop_settings
  for select using (true);

-- escrita só admin. Sem policy de delete de propósito.
create policy shop_settings_admin_insert on public.shop_settings
  for insert to authenticated
  with check (exists (select 1 from public.barbers b where b.id = auth.uid() and b.role = 'admin'));
create policy shop_settings_admin_update on public.shop_settings
  for update to authenticated
  using (exists (select 1 from public.barbers b where b.id = auth.uid() and b.role = 'admin'))
  with check (exists (select 1 from public.barbers b where b.id = auth.uid() and b.role = 'admin'));

-- seed = os valores que já valiam em domain/agenda.ts + o fuso decidido:
--   Seg-Sex 09:00-20:00, Sáb 09:00-18:00, Dom fechado; slot 45 min; janela 10 dias;
--   fuso America/Sao_Paulo.
insert into public.shop_settings (id, slot_min, open_hours, max_advance_days, timezone) values (
  1,
  45,
  '{"0": null, "1": ["09:00","20:00"], "2": ["09:00","20:00"], "3": ["09:00","20:00"], "4": ["09:00","20:00"], "5": ["09:00","20:00"], "6": ["09:00","18:00"]}'::jsonb,
  10,
  'America/Sao_Paulo'
);

grant select on table public.shop_settings to anon, authenticated;
grant insert, update on table public.shop_settings to authenticated;
