-- Categoria de serviço deixa de ser travada em 3 valores fixos (servico/combo/tratamento) —
-- o admin agora pode criar categorias novas direto na tela de Gestão > Serviços.
alter table public.services drop constraint if exists services_category_check;
alter table public.services alter column category set default 'servico';
