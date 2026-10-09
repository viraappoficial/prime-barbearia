-- Confirmação automática ao cliente: acerta o DDI do telefone.
-- clients.phone é cadastrado SEM o 55 (ex.: 44999445716); o gatilho montava o chat com ele cru
-- ("44999445716@c.us"), formato que a WAHA não entende (precisa de DDI) — a confirmação ficava
-- pendente/falhava e ainda aparecia no Zap como uma conversa separada da real. Agora o gatilho
-- põe o 55 só em número que parece brasileiro sem DDI: DDD VÁLIDO (lista da Anatel) + 11 dígitos com
-- 9 na 3ª posição, ou 10 dígitos. Número com "+" ou "00" na frente é internacional e nunca recebe o 55;
-- zero de tronco ("044 ...") é descartado. DDD 55 (Santa Maria) é tratado como DDD, não como DDI.
-- Se o cliente já tem conversa pela outra forma do número (com/sem o nono dígito), usa o chat que existe.
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
  v_raw text;
  v_alt text;
  v_ddds text[] := array['11','12','13','14','15','16','17','18','19','21','22','24','27','28','31','32','33','34','35','37','38','41','42','43','44','45','46','47','48','49','51','53','54','55','61','62','63','64','65','66','67','68','69','71','73','74','75','77','79','81','82','83','84','85','86','87','88','89','91','92','93','94','95','96','97','98','99'];
begin
  if NEW.status = 'confirmado' and (OLD.status is distinct from 'confirmado') then
    if NEW.client_id is not null then
      select c.phone into v_phone from clients c where c.id = NEW.client_id;
    end if;
    v_raw := coalesce(v_phone, NEW.client_phone);
    v_phone := regexp_replace(coalesce(v_raw, ''), '\D', '', 'g');
    if v_phone <> '' then
      if v_raw ~ '^\s*(\+|00)' then
        v_phone := regexp_replace(v_phone, '^00', '');            -- internacional informado de propósito: nunca recebe o 55
      else
        v_phone := regexp_replace(v_phone, '^0+', '');            -- zero de tronco: "044 99944-5716"
        -- brasileiro sem DDI: DDD VÁLIDO + (celular: 11 dígitos com 9 na 3ª posição | fixo/celular antigo: 10 dígitos)
        if substr(v_phone, 1, 2) = any (v_ddds)
           and ((length(v_phone) = 11 and substr(v_phone, 3, 1) = '9')
                or (length(v_phone) = 10 and substr(v_phone, 3, 1) between '2' and '9')) then
          v_phone := '55' || v_phone;
        end if;
      end if;
    end if;
    if v_phone is not null and v_phone <> '' then
      -- se esse cliente JÁ conversa com a barbearia por outra forma do número (com ou sem o nono dígito),
      -- usa o chat que existe: a confirmação cai na mesma conversa em vez de abrir uma duplicada no Zap
      v_alt := case
        when v_phone ~ '^55\d{2}9\d{8}$' then substr(v_phone, 1, 4) || substr(v_phone, 6)            -- com o 9 -> sem
        when v_phone ~ '^55\d{2}[6-9]\d{7}$' then substr(v_phone, 1, 4) || '9' || substr(v_phone, 5)  -- sem o 9 -> com
        else null end;
      if v_alt is not null
         and not exists (select 1 from whatsapp_contacts c where c.chat_id = v_phone || '@c.us')
         and exists (select 1 from whatsapp_contacts c where c.chat_id = v_alt || '@c.us') then
        v_phone := v_alt;
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
