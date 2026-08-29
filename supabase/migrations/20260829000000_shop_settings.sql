-- Config de agenda na tabela de config canônica da loja.
--
-- ⚠️ ACHADO NA APLICAÇÃO (2026-08-28): `public.shop_settings` **JÁ EXISTE** em
-- produção e no lab (baseline linha 1100) — tabela singleton (`id = 1`,
-- check + PK) com `comissao_fiado_na_hora boolean` e `updated_at`. RLS:
--   - `shop_settings_admin_update` (UPDATE só admin) — mantida;
--   - `shop_settings_select_all` (SELECT se `exists(barbers where id=auth.uid())`
--     — na prática, só staff, apesar do nome) — mantida.
--   - `GRANT ALL` a anon/authenticated/service_role.
--
-- Portanto: **ALTER TABLE ADD COLUMN**, não CREATE TABLE. E **UPDATE** da linha
-- id=1 que já existe, não INSERT.
--
-- A leitura da grade pelo frontend/servidor logado-fora NÃO passa pela RLS
-- atual (staff-only). Duas saídas (decisão do Codex — ver doc 03):
--   (B, recomendado) RPC pública `public_shop_grid()` SECURITY DEFINER que
--       devolve SÓ slot_min/open_hours/max_advance_days/timezone (nunca
--       comissao_fiado_na_hora). Sem mexer na policy. → migration 20260829000110.
--   (A) relaxar `shop_settings_select_all` para `using (true)` — expõe também
--       `comissao_fiado_na_hora`.
-- Decisão do Codex (aprovada): ALTER TABLE; preservar `comissao_fiado_na_hora`,
-- as policies (`shop_settings_admin_update`, `shop_settings_select_all`) e os
-- grants existentes; adicionar SÓ as 4 colunas de agenda; o seed atualiza
-- explicitamente SÓ essas 4 colunas da linha id=1 (sem update amplo).
--
-- Rollback:
--   alter table public.shop_settings
--     drop constraint if exists shop_settings_slot_min_chk,
--     drop constraint if exists shop_settings_max_advance_days_chk;
--   alter table public.shop_settings
--     drop column slot_min, drop column open_hours,
--     drop column max_advance_days, drop column timezone;
-- Impacto: nenhum no legado — colunas novas; `comissao_fiado_na_hora`,
-- `updated_at`, policies e grants intocados.

alter table public.shop_settings
  add column slot_min         integer,
  add column open_hours       jsonb,
  add column max_advance_days integer,
  add column timezone         text;

-- seed explícito — SÓ as 4 colunas de agenda da linha id=1 (que já existe).
-- Valores = os que já valiam em domain/agenda.ts + o fuso decidido.
update public.shop_settings set
  slot_min         = 45,
  open_hours       = '{"0": null, "1": ["09:00","20:00"], "2": ["09:00","20:00"], "3": ["09:00","20:00"], "4": ["09:00","20:00"], "5": ["09:00","20:00"], "6": ["09:00","18:00"]}'::jsonb,
  max_advance_days = 10,
  timezone         = 'America/Sao_Paulo'
where id = 1;

-- trava depois do seed (a linha id=1 sempre existe; a trigger/RPCs assumem non-null)
alter table public.shop_settings
  alter column slot_min         set not null,
  alter column open_hours       set not null,
  alter column max_advance_days set not null,
  alter column timezone         set not null;

alter table public.shop_settings
  add constraint shop_settings_slot_min_chk         check (slot_min between 5 and 240),
  add constraint shop_settings_max_advance_days_chk check (max_advance_days between 1 and 90);
