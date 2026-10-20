-- Pagamento online com Pix (Mercado Pago) — Fase 2: base de dados.
-- Plano: docs/pagamento-pix.md. As Edge Functions criar-pix e aviso-mp escrevem aqui com a chave de serviço;
-- o site só lê o estado de um pagamento pelo RPC pix_payment_status e pergunta se uma data exige pagamento.

-- 1) Períodos em que o pagamento antecipado é obrigatório (ex.: dezembro). Leitura pública (o site precisa saber), escrita só admin.
create table if not exists public.payment_rules (
  id bigint generated always as identity primary key,
  label text not null,
  start_day date not null,
  end_day date not null check (end_day >= start_day),
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.payment_rules enable row level security;
drop policy if exists payment_rules_public_read on public.payment_rules;
create policy payment_rules_public_read on public.payment_rules for select using (active);
drop policy if exists payment_rules_admin_all on public.payment_rules;
create policy payment_rules_admin_all on public.payment_rules for all
  using (exists (select 1 from barbers b where b.id = auth.uid() and b.role = 'admin'))
  with check (exists (select 1 from barbers b where b.id = auth.uid() and b.role = 'admin'));
grant select on public.payment_rules to anon, authenticated;
grant insert, update, delete on public.payment_rules to authenticated;

-- 2) Pagamentos antecipados (ainda não são venda: viram uma linha pix_online em sale_payments no fechamento).
create table if not exists public.appointment_payments (
  id uuid primary key default gen_random_uuid(),
  appointment_id bigint not null references public.appointments(id) on delete cascade,
  provider text not null default 'mercadopago',
  provider_payment_id text unique,
  status text not null default 'pendente' check (status in ('pendente', 'aprovado', 'vencido', 'estornado', 'cancelado')),
  amount numeric(10,2) not null check (amount > 0),
  fee numeric(10,2),
  net_amount numeric(10,2),
  pix_qr_code text,
  pix_qr_base64 text,
  ticket_url text,
  payer_cpf_last3 text,                       -- nunca o CPF completo (LGPD)
  expires_at timestamptz not null,
  paid_at timestamptz,
  refunded_at timestamptz,
  needs_refund boolean not null default false, -- pago depois de vencer, com o horário já ocupado
  created_at timestamptz not null default now()
);
create unique index if not exists appointment_payments_one_pending on public.appointment_payments (appointment_id) where status = 'pendente';
create index if not exists appointment_payments_appointment_idx on public.appointment_payments (appointment_id);
alter table public.appointment_payments enable row level security;
drop policy if exists appointment_payments_staff_read on public.appointment_payments;
create policy appointment_payments_staff_read on public.appointment_payments for select
  using (exists (select 1 from barbers b where b.id = auth.uid() and b.role in ('admin', 'vendas')));
grant select on public.appointment_payments to authenticated;

-- 3) Estado do pagamento no agendamento
alter table public.appointments
  add column if not exists payment_status text not null default 'nenhum' check (payment_status in ('nenhum', 'pendente', 'pago', 'estornado')),
  add column if not exists reserved_until timestamptz;

-- 4) Fechamento do carrinho: nova forma de pagamento e taxa real do gateway
alter table public.sale_payments
  add column if not exists taxa_valor numeric(10,2),
  add column if not exists gateway_payment_id text;
alter table public.sale_payments drop constraint if exists sale_payments_method_check;
alter table public.sale_payments add constraint sale_payments_method_check
  check (method = any (array['dinheiro', 'debito', 'credito', 'pix_qrs', 'pix_direto', 'a_prazo', 'pix_online']));

-- 5) A data exige pagamento antecipado?
create or replace function public.payment_required_for(p_day date)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from payment_rules r where r.active and p_day between r.start_day and r.end_day);
$$;
revoke all on function public.payment_required_for(date) from public;
grant execute on function public.payment_required_for(date) to anon, authenticated, service_role;

-- 6) O site pergunta só o estado do próprio pagamento (o uuid é o segredo)
create or replace function public.pix_payment_status(p_payment_id uuid)
returns table (status text, expires_at timestamptz, amount numeric)
language sql stable security definer set search_path = public as $$
  select p.status, p.expires_at, p.amount from appointment_payments p where p.id = p_payment_id;
$$;
revoke all on function public.pix_payment_status(uuid) from public;
grant execute on function public.pix_payment_status(uuid) to anon, authenticated, service_role;

-- 7) Vence os Pix não pagos e libera o horário (obrigatório: cancela o agendamento; opcional: ele continua, pagando no local)
create or replace function public.expirar_pagamentos_pix()
returns integer language plpgsql security definer set search_path = public as $$
declare r record; n integer := 0;
begin
  for r in
    select p.id, p.appointment_id from appointment_payments p
    where p.status = 'pendente' and p.expires_at < now()
    for update skip locked
  loop
    update appointment_payments set status = 'vencido' where id = r.id;
    update appointments a set payment_status = 'nenhum', reserved_until = null where a.id = r.appointment_id;
    update appointments a set status = 'cancelado'
      where a.id = r.appointment_id and a.status = 'pendente' and payment_required_for(a.day);
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke all on function public.expirar_pagamentos_pix() from public, anon, authenticated;
grant execute on function public.expirar_pagamentos_pix() to service_role;

-- 8) Pagamento aprovado (chamado só pela função aviso-mp). Idempotente: aviso repetido não muda nada.
-- Pago depois de vencer: se o horário ainda está livre, volta a valer; se já foi ocupado, fica marcado pra estorno manual.
create or replace function public.registrar_pagamento_aprovado(p_payment_id uuid, p_provider_id text, p_fee numeric, p_net numeric, p_paid_at timestamptz)
returns text language plpgsql security definer set search_path = public as $$
declare p record; a record;
begin
  select * into p from appointment_payments where id = p_payment_id for update;
  if not found then return 'nao_encontrado'; end if;
  if p.status = 'aprovado' then return 'ja_aprovado'; end if;
  if p.status = 'estornado' then return 'ja_estornado'; end if;
  select * into a from appointments where id = p.appointment_id for update;
  if a.status = 'cancelado' then
    begin
      update appointments set status = 'pendente' where id = a.id;   -- o gatilho recusa (SLOT_BLOCKED) se o horário já foi ocupado
    exception when others then
      update appointment_payments set status = 'aprovado', provider_payment_id = coalesce(provider_payment_id, p_provider_id),
        paid_at = p_paid_at, fee = p_fee, net_amount = p_net, needs_refund = true where id = p.id;
      return 'precisa_estorno';
    end;
  end if;
  update appointment_payments set status = 'aprovado', provider_payment_id = coalesce(provider_payment_id, p_provider_id),
    paid_at = p_paid_at, fee = p_fee, net_amount = p_net where id = p.id;
  update appointments set payment_status = 'pago', reserved_until = null where id = a.id;
  return 'ok';
end;
$$;
revoke all on function public.registrar_pagamento_aprovado(uuid, text, numeric, numeric, timestamptz) from public, anon, authenticated;
grant execute on function public.registrar_pagamento_aprovado(uuid, text, numeric, numeric, timestamptz) to service_role;

-- 9) A equipe registra um estorno feito no painel do Mercado Pago
create or replace function public.marcar_pagamento_estornado(p_payment_id uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_app bigint;
begin
  if not exists (select 1 from barbers b where b.id = auth.uid() and b.role in ('admin', 'vendas')) then
    raise exception 'sem permissão';
  end if;
  update appointment_payments set status = 'estornado', refunded_at = now(), needs_refund = false
    where id = p_payment_id and status in ('aprovado', 'vencido') returning appointment_id into v_app;
  if v_app is null then return false; end if;
  update appointments set payment_status = 'estornado' where id = v_app;
  return true;
end;
$$;
revoke all on function public.marcar_pagamento_estornado(uuid) from public, anon;
grant execute on function public.marcar_pagamento_estornado(uuid) to authenticated;

-- 10) Roda a expiração todo minuto, se o pg_cron estiver disponível (senão, agende no painel: Database > Cron)
do $$
begin
  begin
    create extension if not exists pg_cron;
  exception when others then
    raise notice 'pg_cron indisponível (%): agende expirar_pagamentos_pix() a cada minuto no painel', sqlerrm;
  end;
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('expirar-pix', '* * * * *', 'select public.expirar_pagamentos_pix()');
  end if;
end $$;
