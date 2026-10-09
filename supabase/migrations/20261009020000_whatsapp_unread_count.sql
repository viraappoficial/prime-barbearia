-- Contador de não lidas por conversa, igual WhatsApp: soma quem é inbound e chegou depois do
-- último "abri essa conversa" da equipe (last_read_at). Zera quando alguém da equipe abre o
-- chat (mark_chat_read) — é uma só marca por conversa, compartilhada entre a equipe toda
-- (mesma lógica do resto do Zap: é uma caixa de entrada, não uma por pessoa).

alter table public.whatsapp_contacts add column if not exists last_read_at timestamptz;

-- Backfill: sem isso, toda conversa já existente apareceria com um número gigante de "não
-- lidas" (todo o histórico) na hora que o recurso entrar no ar — marca tudo como lido até agora.
update public.whatsapp_contacts set last_read_at = now() where last_read_at is null;

create or replace function public.mark_chat_read(p_chat_id text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from barbers b where b.id = auth.uid() and b.role in ('vendas','admin')) then
    raise exception 'sem permissão';
  end if;
  insert into whatsapp_contacts (chat_id, last_read_at)
  values (p_chat_id, now())
  on conflict (chat_id) do update set last_read_at = excluded.last_read_at;
end;
$$;
revoke all on function public.mark_chat_read(text) from public;
grant execute on function public.mark_chat_read(text) to authenticated;

-- security_invoker respeita a RLS de quem consulta (vendas/admin), mesmo padrão de
-- whatsapp_conversations. Conversa sem linha em whatsapp_contacts ainda (mensagem acabou de
-- chegar, ensureContactFresh é fire-and-forget) conta tudo como não lida — correto, é novo.
create or replace view public.whatsapp_unread_counts
with (security_invoker = true) as
select m.chat_id, count(*) as unread_count
from whatsapp_messages m
left join whatsapp_contacts c on c.chat_id = m.chat_id
where m.direction = 'inbound' and m.created_at > coalesce(c.last_read_at, '-infinity'::timestamptz)
group by m.chat_id;
