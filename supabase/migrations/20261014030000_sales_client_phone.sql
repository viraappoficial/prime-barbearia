-- Telefone do cliente em cada venda (balcão/PDV), pra reconhecer a pessoa na próxima vez.
--
-- Por quê: venda de balcão de quem ainda não tem conta guardava só o nome (sales.client_name). Com o telefone gravado,
-- quando a pessoa agendar/mandar mensagem pelo WhatsApp ou criar a conta, o histórico dela é achado pelo número
-- (com/sem DDI e com/sem o nono dígito, mesma regra do resto do sistema) e aparece na ficha do Zap e no Atendimento.
--
-- Formato: só dígitos SEM o 55 (igual clients.phone). Coluna opcional: venda antiga e venda sem telefone ficam nulas.
-- Não muda RLS (quem já lê/grava vendas continua igual) e não mexe em dado existente.
-- O site funciona antes e depois desta migration (se a coluna não existe, grava a venda sem o telefone).
--
-- Rollback: drop index if exists public.sales_client_phone_idx; alter table public.sales drop column if exists client_phone;
-- Impacto: só adiciona uma coluna nula e um índice parcial.

alter table public.sales add column if not exists client_phone text;

create index if not exists sales_client_phone_idx on public.sales (client_phone) where client_phone is not null;

comment on column public.sales.client_phone is 'Telefone do cliente só com dígitos, sem DDI (55). Opcional.';
