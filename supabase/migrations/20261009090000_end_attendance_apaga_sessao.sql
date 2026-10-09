-- end_attendance: depois de encerrar, a próxima mensagem do cliente tem que ser tratada como
-- conversa NOVA (saudação + menu). Antes a função só resetava a sessão pra step='menu' com
-- last_options nulo; a URA então lia o "Oi" como resposta do menu, não achava a opção e mandava
-- "Opa, não entendi..." antes de mostrar o menu. Apagar a linha da sessão faz o contato cair no
-- mesmo caminho do primeiro contato (sem sessão), que já sabe cumprimentar.
--
-- Rollback: reaplicar end_attendance da migration 20261009070000_fix_end_attendance_service_ids.sql
-- Impacto: só o botão "Encerrar" do Zap; não mexe em mensagens nem em agendamentos.

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

  delete from whatsapp_ura_sessions where chat_id = p_chat_id;
end;
$$;
