-- Contas bancárias só tinham "nome", ficando um texto solto sem contexto.
-- Adiciona agência e número da conta (ambos opcionais).
alter table public.bank_accounts
  add column agencia text,
  add column conta text;
