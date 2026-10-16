-- Cancelamento feito pela barbearia: avisa o cliente sozinho pelo WhatsApp (chip da barbearia), pedindo desculpas e
-- oferecendo outro horário com outro barbeiro. Antes, o app só abria uma aba do wa.me pra alguém enviar à mão.
--
-- notify_client_appointment_cancelled(p_appt_id): enfileira UMA mensagem em whatsapp_messages (pending, sem canal — o servidor
-- do bot adota o canal padrão e envia). Só funciona pra agendamento já 'cancelado'. Devolve true se enfileirou, false se não há
-- telefone (o app então cai no wa.me manual de sempre). Qualquer pessoa da equipe logada pode chamar (barbeiro, vendas, admin).
-- O texto tem 3 variações (sorteadas) pra não sair sempre igual; a equipe pode trocar por um texto fixo criando a configuração
-- 'cancel_by_barber_message' em whatsapp_ura_settings (variáveis: {nome} {dia} {hora} {barbeiro}).
--
-- Rollback: drop function public.notify_client_appointment_cancelled(bigint);
-- Impacto: só passa a existir a função; nada muda até o app (index.html) chamá-la.

create or replace function public.notify_client_appointment_cancelled(p_appt_id bigint)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  a record;
  v_raw text;
  v_phone text;
  v_nome text;
  v_barber text;
  v_dia text;
  v_hora text;
  v_custom text;
  v_msg text;
  v_saudacao text;
begin
  if not exists (select 1 from barbers b where b.id = auth.uid()) then
    raise exception 'sem permissão';
  end if;

  select * into a from appointments where id = p_appt_id;
  if not found or a.status is distinct from 'cancelado' then
    return false;
  end if;

  if a.client_id is not null then
    select c.phone, c.name into v_raw, v_nome from clients c where c.id = a.client_id;
  end if;
  v_raw := coalesce(nullif(v_raw, ''), a.client_phone);
  v_nome := split_part(coalesce(nullif(v_nome, ''), a.client_name, ''), ' ', 1);

  v_phone := regexp_replace(coalesce(v_raw, ''), '\D', '', 'g');
  if v_phone = '' then
    return false;
  end if;
  if v_raw ~ '^\s*(\+|00)' then
    v_phone := regexp_replace(v_phone, '^00', '');          -- internacional informado de propósito: nunca recebe o 55
  else
    v_phone := regexp_replace(v_phone, '^0+', '');          -- zero de tronco
    if length(v_phone) in (10, 11) then
      v_phone := '55' || v_phone;                           -- brasileiro sem DDI (a fila tenta a outra forma do 9 se precisar)
    end if;
  end if;

  select name into v_barber from barbers where id = a.barber_id;
  v_barber := coalesce(nullif(v_barber, ''), 'barbeiro');
  v_dia := coalesce(nullif(a.day_label, ''), to_char(a.day::date, 'DD/MM'));
  v_hora := left(a.time::text, 5);
  v_saudacao := case when v_nome <> '' then ', ' || v_nome else '' end;

  select value into v_custom from whatsapp_ura_settings where key = 'cancel_by_barber_message';
  v_msg := coalesce(
    nullif(v_custom, ''),
    case 1 + floor(random() * 3)::int
      when 1 then 'Oi{saudacao}! Precisamos cancelar seu horário de {dia} às {hora} com o {barbeiro}. Pedimos desculpas pelo transtorno 🙏 Quer que eu veja outro horário com outro barbeiro? É só responder por aqui.'
      when 2 then 'Oi{saudacao}, tudo bem? Infelizmente o {barbeiro} não vai conseguir te atender em {dia} às {hora} e o horário foi cancelado. Desculpa o imprevisto! Posso te encaixar com outro barbeiro? É só me dizer.'
      else 'Oi{saudacao}, passando pra avisar que seu horário de {dia} às {hora} com o {barbeiro} precisou ser cancelado. Nos desculpe 🙏 Quer marcar outro horário, com outro barbeiro? Me responde por aqui que eu vejo pra você.'
    end
  );
  v_msg := replace(v_msg, '{saudacao}', v_saudacao);
  v_msg := replace(replace(replace(replace(v_msg, '{nome}', v_nome), '{dia}', v_dia), '{hora}', v_hora), '{barbeiro}', v_barber);

  insert into whatsapp_messages (chat_id, contact_phone, direction, status, body)
  values (v_phone || '@c.us', v_phone, 'outbound', 'pending', v_msg);
  return true;
end;
$$;

revoke all on function public.notify_client_appointment_cancelled(bigint) from public;
grant execute on function public.notify_client_appointment_cancelled(bigint) to authenticated;
