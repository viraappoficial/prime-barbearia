-- Confirmação ao cliente com texto VARIADO (mensagem idêntica repetida é sinal de automação pro WhatsApp).
-- Se o texto configurado (appointment_confirmed_template) for o padrão antigo ou estiver vazio, sorteia entre 4 variações com o nome do cliente.
-- Texto personalizado pela equipe continua sendo usado como está. Resto da função igual à anterior.
create or replace function public.notify_appointment_confirmed()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare
  v_phone text;
  v_barber_name text;
  v_template text;
  v_message text;
  v_raw text;
  v_alt text;
  v_nome text;
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
        v_phone := regexp_replace(v_phone, '^00', '');
      else
        v_phone := regexp_replace(v_phone, '^0+', '');
        if substr(v_phone, 1, 2) = any (v_ddds)
           and ((length(v_phone) = 11 and substr(v_phone, 3, 1) = '9')
                or (length(v_phone) = 10 and substr(v_phone, 3, 1) between '2' and '9')) then
          v_phone := '55' || v_phone;
        end if;
      end if;
    end if;
    if v_phone is not null and v_phone <> '' then
      v_alt := case
        when v_phone ~ '^55\d{2}9\d{8}$' then substr(v_phone, 1, 4) || substr(v_phone, 6)
        when v_phone ~ '^55\d{2}[6-9]\d{7}$' then substr(v_phone, 1, 4) || '9' || substr(v_phone, 5)
        else null end;
      if v_alt is not null
         and not exists (select 1 from whatsapp_contacts c where c.chat_id = v_phone || '@c.us')
         and exists (select 1 from whatsapp_contacts c where c.chat_id = v_alt || '@c.us') then
        v_phone := v_alt;
      end if;
      select b.name into v_barber_name from barbers b where b.id = NEW.barber_id;
      select value into v_template from whatsapp_ura_settings where key = 'appointment_confirmed_template';
      v_nome := coalesce(nullif(split_part(btrim(coalesce(NEW.client_name, '')), ' ', 1), ''), '');
      if v_template is null or v_template = '' or v_template like 'O barbeiro {barbeiro} acabou de confirmar seu agendamento:%' then
        v_message := case 1 + floor(random() * 4)::int
          when 1 then 'Oi{saudacao}! O {barbeiro} confirmou seu horário: {servicos}, {dia} às {hora}. Te esperamos! ✂️'
          when 2 then 'Tudo certo{saudacao}! Seu horário está confirmado com o {barbeiro}: {servicos}, {dia} às {hora}. Até lá! 💈'
          when 3 then 'Boa{saudacao}, o {barbeiro} já confirmou: {servicos}, {dia} às {hora}. Qualquer imprevisto é só avisar por aqui.'
          else 'Confirmado{saudacao}! {servicos} com o {barbeiro}, {dia} às {hora}. Vai ser um prazer te receber ✂️'
        end;
      else
        v_message := v_template;
      end if;
      v_message := replace(v_message, '{saudacao}', case when v_nome <> '' then ', ' || v_nome else '' end);
      v_message := replace(v_message, '{nome}', v_nome);
      v_message := replace(v_message, '{barbeiro}', coalesce(v_barber_name, 'da Prime'));
      v_message := replace(v_message, '{servicos}', array_to_string(NEW.services, ' + '));
      v_message := replace(v_message, '{dia}', NEW.day_label);
      v_message := replace(v_message, '{hora}', NEW.time);
      insert into whatsapp_messages (chat_id, contact_phone, direction, status, body, kind, template_name, template_lang, template_params)
      values (v_phone || '@c.us', v_phone, 'outbound', 'pending', v_message, 'template', 'confirmacao_agendamento', 'pt_BR',
        jsonb_build_array(
          coalesce(nullif(v_nome, ''), 'cliente'),
          coalesce(v_barber_name, 'da Prime'),
          coalesce(nullif(array_to_string(NEW.services, ' + '), ''), 'seu horário'),
          coalesce(NEW.day_label, '') || ' às ' || coalesce(NEW.time, '')));
    end if;
  end if;
  return NEW;
end;
$function$;
