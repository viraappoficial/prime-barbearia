-- De onde veio a mensagem de saída: 'crm' = botão do CRM (campanha para quem pode estar frio; segue os limites do número,
-- sem exigir autorização um a um). Rollback: alter table public.whatsapp_messages drop column origem;
alter table public.whatsapp_messages add column if not exists origem text;
