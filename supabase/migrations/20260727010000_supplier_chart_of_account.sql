-- Liga cada fornecedor a um plano de conta (ex: sistema/mensalidade, contabilidade,
-- produtos capilares) — usado pra classificar o fornecedor e sugerir a categoria
-- certa na hora de lançar uma conta a pagar pra ele.
alter table public.suppliers
  add column chart_of_account_id bigint references public.chart_of_accounts(id) on delete set null;
