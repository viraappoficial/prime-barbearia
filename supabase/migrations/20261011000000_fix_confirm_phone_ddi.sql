-- Confirmação automática ao cliente: acerta o DDI do telefone.
-- clients.phone é cadastrado SEM o 55 (ex.: 44999445716); o gatilho montava o chat com ele cru
-- ("44999445716@c.us"), formato que a WAHA não entende (precisa de DDI) — a confirmação ficava
-- pendente/falhava e ainda aparecia no Zap como uma conversa separada da real. Agora o gatilho
-- põe o 55 em número brasileiro sem DDI (11 dígitos com 9 na 3ª posição, ou 10 dígitos de fixo).
-- Resto da função igual à da migration 20261008050000_whatsapp_ura.sql.
--
-- Rollback: reaplicar notify_appointment_confirmed da migration 20261008050000_whatsapp_ura.sql
-- Impacto: só o destino da mensagem de confirmação.

create or replace function public.notify_appointment_confirmed()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_phone text;
  v_barber_name text;
  v_template text;
  v_message text;
begin
  if NEW.status = 'confirmado' and (OLD.status is distinct from 'confirmado') then
    if NEW.client_id is not null then
      select c.phone into v_phone from clients c where c.id = NEW.client_id;
    end if;
    v_phone := regexp_replace(coalesce(v_phone, NEW.client_phone), '\D', '', 'g');
    if v_phone is not null and v_phone <> '' then
      -- sem DDI: celular (11 dígitos, 9 na 3ª posição) ou fixo (10 dígitos) -> acrescenta o 55
      if (length(v_phone) = 11 and substr(v_phone, 3, 1) = '9')
         or (length(v_phone) = 10 and substr(v_phone, 3, 1) between '2' and '8') then
        v_phone := '55' || v_phone;
      end if;
      select b.name into v_barber_name from barbers b where b.id = NEW.barber_id;
      select value into v_template from whatsapp_ura_settings where key = 'appointment_confirmed_template';
      v_message := coalesce(v_template, 'O barbeiro {barbeiro} acabou de confirmar seu agendamento: {servicos}, dia {dia} às {hora}. Te esperamos! ✂️');
      v_message := replace(v_message, '{barbeiro}', coalesce(v_barber_name, 'da Prime'));
      v_message := replace(v_message, '{servicos}', array_to_string(NEW.services, ' + '));
      v_message := replace(v_message, '{dia}', NEW.day_label);
      v_message := replace(v_message, '{hora}', NEW.time);
      insert into whatsapp_messages (chat_id, contact_phone, direction, status, body)
      values (v_phone || '@c.us', v_phone, 'outbound', 'pending', v_message);
    end if;
  end if;
  return NEW;
end;
$$;
