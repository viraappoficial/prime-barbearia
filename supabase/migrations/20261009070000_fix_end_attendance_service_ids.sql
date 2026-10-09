-- Corrige end_attendance: a migração da multi-seleção de serviço trocou
-- whatsapp_ura_sessions.service_id (coluna única) por service_ids (array) e removeu a coluna
-- antiga, mas essa função ainda tentava zerar `service_id` — toda chamada falhava com "column
-- service_id does not exist", em QUALQUER chat (não só no meio da URA, apesar da aparência).
create or replace function public.end_attendance(p_chat_id text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_phone text;
  v_message text;
begin
  if not exists (select 1 from barbers b where b.id = auth.uid() and b.role in ('vendas','admin')) then
    raise exception 'sem permissão';
  end if;

  v_phone := regexp_replace(split_part(p_chat_id, '@', 1), '\D', '', 'g');
  if v_phone <> '' then
    select value into v_message from whatsapp_ura_settings where key = 'closing_message';
    insert into whatsapp_messages (chat_id, contact_phone, direction, status, body)
    values (p_chat_id, v_phone, 'outbound', 'pending',
            coalesce(v_message, 'Por hoje é só! Qualquer coisa é só mandar mensagem de novo por aqui. Até mais! 👋'));
  end if;

  update whatsapp_contacts
    set handoff_requested = false, assumed_by = null, assumed_at = null
    where chat_id = p_chat_id;

  update whatsapp_ura_sessions
    set step = 'menu', service_ids = null, barber_id = null, day = null, time = null,
        last_options = null, pending_appointment_id = null, updated_at = now()
    where chat_id = p_chat_id;
end;
$$;
