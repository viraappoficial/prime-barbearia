-- Contas a Pagar: fornecedores, instituições financeiras, plano de contas editável,
-- e colunas novas em expenses (vencimento, parcelamento, status pago/pendente, baixa).
-- Nada existente é removido; expenses.date/category/value continuam alimentando
-- os cards de Despesas do mês, Lucro líquido e DRE exatamente como hoje.

create table public.suppliers (
  id bigint generated always as identity primary key,
  name text not null,
  phone text,
  website text,
  created_at timestamptz not null default now()
);
alter table public.suppliers enable row level security;
create policy suppliers_admin_select on public.suppliers for select
  using (exists (select 1 from barbers b where b.id = auth.uid() and b.role = 'admin'));
create policy suppliers_admin_insert on public.suppliers for insert
  with check (exists (select 1 from barbers b where b.id = auth.uid() and b.role = 'admin'));
create policy suppliers_admin_update on public.suppliers for update
  using (exists (select 1 from barbers b where b.id = auth.uid() and b.role = 'admin'))
  with check (exists (select 1 from barbers b where b.id = auth.uid() and b.role = 'admin'));
create policy suppliers_admin_delete on public.suppliers for delete
  using (exists (select 1 from barbers b where b.id = auth.uid() and b.role = 'admin'));

create table public.bank_accounts (
  id bigint generated always as identity primary key,
  name text not null,
  created_at timestamptz not null default now()
);
alter table public.bank_accounts enable row level security;
create policy bank_accounts_admin_select on public.bank_accounts for select
  using (exists (select 1 from barbers b where b.id = auth.uid() and b.role = 'admin'));
create policy bank_accounts_admin_insert on public.bank_accounts for insert
  with check (exists (select 1 from barbers b where b.id = auth.uid() and b.role = 'admin'));
create policy bank_accounts_admin_update on public.bank_accounts for update
  using (exists (select 1 from barbers b where b.id = auth.uid() and b.role = 'admin'))
  with check (exists (select 1 from barbers b where b.id = auth.uid() and b.role = 'admin'));
create policy bank_accounts_admin_delete on public.bank_accounts for delete
  using (exists (select 1 from barbers b where b.id = auth.uid() and b.role = 'admin'));

create table public.chart_of_accounts (
  id bigint generated always as identity primary key,
  slug text not null unique,
  name text not null,
  is_taxa_maquininha boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.chart_of_accounts enable row level security;
create policy chart_of_accounts_admin_select on public.chart_of_accounts for select
  using (exists (select 1 from barbers b where b.id = auth.uid() and b.role = 'admin'));
create policy chart_of_accounts_admin_insert on public.chart_of_accounts for insert
  with check (exists (select 1 from barbers b where b.id = auth.uid() and b.role = 'admin'));
create policy chart_of_accounts_admin_update on public.chart_of_accounts for update
  using (exists (select 1 from barbers b where b.id = auth.uid() and b.role = 'admin'))
  with check (exists (select 1 from barbers b where b.id = auth.uid() and b.role = 'admin'));
create policy chart_of_accounts_admin_delete on public.chart_of_accounts for delete
  using (exists (select 1 from barbers b where b.id = auth.uid() and b.role = 'admin'));

insert into public.chart_of_accounts (slug, name, is_taxa_maquininha) values
  ('aluguel', 'Aluguel', false),
  ('energia', 'Energia', false),
  ('agua_internet', 'Água/Internet', false),
  ('salarios', 'Salários', false),
  ('produtos', 'Produtos e materiais', false),
  ('marketing', 'Marketing', false),
  ('software', 'Software', false),
  ('taxa_maquininha', 'Taxa de maquininha', true),
  ('outros', 'Outros', false);

alter table public.expenses
  add column supplier_id bigint references public.suppliers(id) on delete set null,
  add column due_date date,
  add column payment_type text not null default 'normal' check (payment_type in ('normal', 'parcelado')),
  add column installment_number int,
  add column installment_total int,
  add column installment_group_id uuid,
  add column status text not null default 'pendente' check (status in ('pago', 'pendente')),
  add column paid_at date,
  add column paid_method text check (paid_method in ('dinheiro', 'banco')),
  add column bank_account_id bigint references public.bank_accounts(id) on delete set null;

-- despesas já lançadas antes desta migration eram tratadas como já quitadas
update public.expenses set status = 'pago' where status = 'pendente';
