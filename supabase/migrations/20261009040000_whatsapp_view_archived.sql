-- Ver arquivados: lista espelhada de whatsapp_conversations, só que com os arquivados (o
-- inverso exato do filtro de lá). Mesma régua: se a última mensagem for mais nova que o
-- arquivamento, já não entra aqui (já voltou pra lista normal sozinha).
create or replace view public.whatsapp_archived_conversations
with (security_invoker = true) as
select latest.chat_id, latest.contact_phone, latest.last_body, latest.last_direction, latest.last_status, latest.last_at
from (
  select distinct on (m.chat_id)
    m.chat_id, m.contact_phone, m.body as last_body, m.direction as last_direction,
    m.status as last_status, m.created_at as last_at
  from whatsapp_messages m
  order by m.chat_id, m.created_at desc
) latest
join whatsapp_contacts c on c.chat_id = latest.chat_id
where c.archived_at is not null and latest.last_at <= c.archived_at;

create or replace function public.unarchive_whatsapp_chat(p_chat_id text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from barbers b where b.id = auth.uid() and b.role in ('vendas','admin')) then
    raise exception 'sem permissão';
  end if;
  update whatsapp_contacts set archived_at = null where chat_id = p_chat_id;
end;
$$;
revoke all on function public.unarchive_whatsapp_chat(text) from public;
grant execute on function public.unarchive_whatsapp_chat(text) to authenticated;
