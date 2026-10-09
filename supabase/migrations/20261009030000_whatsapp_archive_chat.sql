-- "Tirar da lista" (arquivar, igual WhatsApp): some da lista de Atendimento sem apagar nada —
-- se chegar mensagem nova depois, volta sozinha. whatsapp_conversations passa a considerar isso.

alter table public.whatsapp_contacts add column if not exists archived_at timestamptz;

create or replace function public.archive_whatsapp_chat(p_chat_id text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from barbers b where b.id = auth.uid() and b.role in ('vendas','admin')) then
    raise exception 'sem permissão';
  end if;
  insert into whatsapp_contacts (chat_id, archived_at)
  values (p_chat_id, now())
  on conflict (chat_id) do update set archived_at = excluded.archived_at;
end;
$$;
revoke all on function public.archive_whatsapp_chat(text) from public;
grant execute on function public.archive_whatsapp_chat(text) to authenticated;

-- Recria a view (mesmas colunas/ordem de 20261008010000_whatsapp_conversations_view.sql, só
-- acrescenta o filtro de arquivado) — exclui chat arquivado A MENOS que a última mensagem seja
-- mais nova que o arquivamento (chegou algo novo depois de arquivar = volta pra lista sozinha).
create or replace view public.whatsapp_conversations
with (security_invoker = true) as
select latest.chat_id, latest.contact_phone, latest.last_body, latest.last_direction, latest.last_status, latest.last_at
from (
  select distinct on (m.chat_id)
    m.chat_id, m.contact_phone, m.body as last_body, m.direction as last_direction,
    m.status as last_status, m.created_at as last_at
  from whatsapp_messages m
  order by m.chat_id, m.created_at desc
) latest
left join whatsapp_contacts c on c.chat_id = latest.chat_id
where c.archived_at is null or latest.last_at > c.archived_at;
