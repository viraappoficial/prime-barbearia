-- Encerrar atendimento: fecha a conversa (reseta a URA pro menu, limpa handoff/assumido) e manda
-- uma mensagem de despedida. Duas formas de disparar: botão manual no Zap (RPC abaixo) ou
-- automático depois de 10min sem resposta do cliente num meio de fluxo (feito pelo
-- prime-whatsapp-server, ver sweepIdleSessions em ura.ts — não depende de SQL pra isso).

insert into whatsapp_ura_settings (key, value) values
  ('closing_message', 'Por hoje é só! Qualquer coisa é só mandar mensagem de novo por aqui. Até mais! 👋')
on conflict (key) do nothing;

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
    set step = 'menu', service_id = null, barber_id = null, day = null, time = null,
        last_options = null, pending_appointment_id = null, updated_at = now()
    where chat_id = p_chat_id;
end;
$$;
revoke all on function public.end_attendance(text) from public;
grant execute on function public.end_attendance(text) to authenticated;
