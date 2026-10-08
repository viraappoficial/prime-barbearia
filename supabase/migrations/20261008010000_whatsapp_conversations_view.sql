-- Lista de conversas pra aba Zap — 1 linha por chat_id com a última mensagem. security_invoker
-- faz a view respeitar a RLS de quem consulta (vendas/admin), não a de quem criou a view.
create view public.whatsapp_conversations
with (security_invoker = true) as
select distinct on (chat_id)
  chat_id,
  contact_phone,
  body as last_body,
  direction as last_direction,
  status as last_status,
  created_at as last_at
from public.whatsapp_messages
order by chat_id, created_at desc;
