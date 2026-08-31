-- ST-2.2 — schema aditivo do checkout (snapshot em `sales`, motivo de desconto,
-- tetos de desconto por papel em `shop_settings`).
--
-- TODAS as colunas são aditivas e nullable / com default → o `#barberApp`
-- legado (que não as conhece) segue escrevendo `sales`/`appointments` como
-- antes. Nada é `NOT NULL` sem default.
--
-- Decisão comercial (Gabriel, aprovada): barbeiro pode dar até 15% de desconto;
-- vendas até 20%; admin até 100%. Desconto acima de 20% (o "threshold") exige
-- `motivo` obrigatório — a RPC recusa com `DISCOUNT_MOTIVO_REQUIRED`.
--
-- Rollback:
--   alter table public.sales         drop column if exists unit_price;
--   alter table public.sales         drop column if exists discount;
--   alter table public.sales         drop column if exists discount_motivo;
--   alter table public.appointments  drop column if exists discount_motivo;
--   alter table public.shop_settings drop column if exists max_discount_barbeiro;
--   alter table public.shop_settings drop column if exists max_discount_vendas;
--   alter table public.shop_settings drop column if exists max_discount_admin;
--   alter table public.shop_settings drop column if exists discount_motivo_threshold;
-- Impacto no legado: nenhum — colunas novas nullable/com default; o guard de
-- coluna `_appointments_guard_update` continua NÃO listando `discount_motivo`
-- para staff → só a RPC (owner) a grava.

-- ── sales: snapshot de preço/desconto (D-ST2-8) ──────────────────────────────
alter table public.sales add column if not exists unit_price      numeric;
alter table public.sales add column if not exists discount         numeric;
alter table public.sales add column if not exists discount_motivo  text;

comment on column public.sales.unit_price is
  'ST-2: preço de tabela no momento da venda (linha de serviço = soma dos serviços; linha de produto = preço unitário). Snapshot — nunca ponteiro pro preço atual.';
comment on column public.sales.discount is
  'ST-2: desconto absoluto aplicado (só na linha de serviço). unit_price - value.';
comment on column public.sales.discount_motivo is
  'ST-2: motivo do desconto quando o percentual excede shop_settings.discount_motivo_threshold.';

-- ── appointments: motivo de desconto persistido pelo carrinho ────────────────
alter table public.appointments add column if not exists discount_motivo text;

comment on column public.appointments.discount_motivo is
  'ST-2: motivo do desconto do carrinho (persistido por staff_cart_set_services quando o percentual excede o threshold). Gravado só pela RPC (fora da allow-list do guard).';

-- ── shop_settings: tetos de desconto por papel + threshold do motivo ─────────
alter table public.shop_settings add column if not exists max_discount_barbeiro     numeric not null default 15;
alter table public.shop_settings add column if not exists max_discount_vendas       numeric not null default 20;
alter table public.shop_settings add column if not exists max_discount_admin        numeric not null default 100;
alter table public.shop_settings add column if not exists discount_motivo_threshold numeric not null default 20;

do $$ begin
  alter table public.shop_settings
    add constraint shop_settings_discount_pct_chk
    check (max_discount_barbeiro between 0 and 100
       and max_discount_vendas    between 0 and 100
       and max_discount_admin     between 0 and 100
       and discount_motivo_threshold between 0 and 100);
exception when duplicate_object then null; end $$;

comment on column public.shop_settings.max_discount_barbeiro is
  'ST-2: teto de desconto (%) que um barbeiro pode aplicar. Decisão comercial: 15.';
comment on column public.shop_settings.max_discount_vendas is
  'ST-2: teto de desconto (%) que vendas pode aplicar. Decisão comercial: 20.';
comment on column public.shop_settings.max_discount_admin is
  'ST-2: teto de desconto (%) que admin pode aplicar. Decisão comercial: 100.';
comment on column public.shop_settings.discount_motivo_threshold is
  'ST-2: acima deste percentual o desconto exige motivo obrigatório. Decisão comercial: 20.';

-- default-deny para coluna futura: o guard de `appointments` já é allow-list
-- dinâmica; `sales`/`shop_settings` não têm guard (staff não escreve `sales`
-- por RLS; `shop_settings` só admin). Nada a fazer aqui.
