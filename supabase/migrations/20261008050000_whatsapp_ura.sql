-- URA do WhatsApp (V1 sem IA) — fluxo de menu/lista determinístico, 100% automático. Estado da
-- conversa por telefone fica todo no banco (nada em memória do processo — o servidor de casa
-- pode cair/reiniciar sem perder o passo). Só o servidor de casa (service_role) lê/escreve aqui.
create table public.whatsapp_ura_sessions (
  chat_id text primary key,
  step text not null default 'menu',  -- menu | svc | barber | day | time | confirm | human
  service_id bigint references public.services(id),
  barber_id uuid references public.barbers(id),
  day date,
  time text,
  -- Menu é por número digitado ("responde 1, 2 ou 3"), não lista clicável — não depende de
  -- renderização nativa do WhatsApp, que é instável em libs não-oficiais. Guarda exatamente quais
  -- opções foram oferecidas na última mensagem (em ordem), pra interpretar "2" sem precisar
  -- reconsultar o banco (e arriscar a lista ter mudado entre a pergunta e a resposta).
  last_options jsonb,
  -- segura o id do agendamento entre "escolheu cancelar esse" e "confirmou o cancelamento"
  -- (passo cancel_confirm) — nunca reaproveita as colunas day/time pra isso.
  pending_appointment_id bigint references public.appointments(id),
  updated_at timestamptz not null default now()
);
alter table public.whatsapp_ura_sessions enable row level security;
-- sem policy nenhuma: só service_role (o próprio servidor de casa) toca aqui, nunca o navegador
-- nem o cliente final — não é dado que a equipe precisa ver direto (a equipe vê pela lista de
-- conversas / badge de handoff, não pela tabela de sessão).

-- Base configurável da URA: toda mensagem que o bot manda vive aqui, editável pela equipe numa
-- tela dentro do ViraDeck — sem precisar alterar código pra mudar um texto.
create table public.whatsapp_ura_settings (
  key text primary key,
  value text not null,
  updated_at timestamptz not null default now()
);
alter table public.whatsapp_ura_settings enable row level security;
create policy whatsapp_ura_settings_staff_read on public.whatsapp_ura_settings for select
  using (exists (select 1 from barbers b where b.id = auth.uid() and b.role in ('vendas','admin')));

create or replace function public.update_ura_setting(p_key text, p_value text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from barbers b where b.id = auth.uid() and b.role in ('vendas','admin')) then
    raise exception 'sem permissão';
  end if;
  insert into whatsapp_ura_settings (key, value, updated_at)
  values (p_key, p_value, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
end; $$;
revoke all on function public.update_ura_setting(text, text) from public;
grant execute on function public.update_ura_setting(text, text) to authenticated;

insert into whatsapp_ura_settings (key, value) values
  ('bot_enabled', 'true'),
  ('menu_message', 'Oi! Eu sou o assistente da Prime Barbearia 💈'),
  ('menu_option_agendar', 'Agendar horário'),
  ('menu_option_meus_agendamentos', 'Ver meus agendamentos'),
  ('menu_option_servicos', 'Ver serviços e preços'),
  ('menu_option_endereco', 'Endereço e horário'),
  ('address_info', e'Av. Pedro Taques, 2824 - Maringá, PR\nSeg a sex: 09h às 20h | Sáb: 09h às 18h | Dom: fechado'),
  ('menu_option_atendente', 'Falar com atendente'),
  ('ask_service', 'Qual serviço você quer agendar?'),
  ('ask_barber', 'Com qual barbeiro?'),
  ('ask_day', 'Pra qual dia?'),
  ('ask_time', 'Escolhe um horário disponível:'),
  ('no_slots_available', 'Não tem horário livre nesse dia pra esse barbeiro 😕 Escolhe outro dia ou outro barbeiro.'),
  ('confirm_summary_template', e'Confirma esse agendamento?\n{servicos} com {barbeiro}\n{dia} às {hora}'),
  ('confirm_success', 'Agendado! ✂️ Te esperamos {dia} às {hora}. Qualquer imprevisto, volta aqui.'),
  ('confirm_conflict', 'Esse horário acabou de ser ocupado 😕 Escolhe outro:'),
  ('fallback_message', 'Não entendi 🤔 Escolhe uma das opções abaixo:'),
  ('handoff_message', 'Já vou chamar alguém da equipe pra te atender por aqui, só um instante 🙂'),
  ('appointment_confirmed_template', 'O barbeiro {barbeiro} acabou de confirmar seu agendamento: {servicos}, dia {dia} às {hora}. Te esperamos! ✂️')
on conflict (key) do nothing;

-- Handoff (assumir chat): quando o cliente pede "falar com atendente", ou a URA não reconhece a
-- resposta dele repetidamente, fica marcado aqui até alguém da equipe assumir pelo Zap.
alter table public.whatsapp_contacts
  add column if not exists handoff_requested boolean not null default false,
  add column if not exists assumed_by uuid references public.barbers(id),
  add column if not exists assumed_at timestamptz;

create or replace function public.assume_whatsapp_chat(p_chat_id text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from barbers b where b.id = auth.uid() and b.role in ('vendas','admin')) then
    raise exception 'sem permissão';
  end if;
  update whatsapp_contacts
    set handoff_requested = false, assumed_by = auth.uid(), assumed_at = now()
    where chat_id = p_chat_id;
  update whatsapp_ura_sessions set step = 'human', updated_at = now() where chat_id = p_chat_id;
end; $$;
revoke all on function public.assume_whatsapp_chat(text) from public;
grant execute on function public.assume_whatsapp_chat(text) to authenticated;

create or replace function public.release_whatsapp_chat(p_chat_id text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from barbers b where b.id = auth.uid() and b.role in ('vendas','admin')) then
    raise exception 'sem permissão';
  end if;
  update whatsapp_contacts set assumed_by = null, assumed_at = null where chat_id = p_chat_id;
  update whatsapp_ura_sessions set step = 'menu', updated_at = now() where chat_id = p_chat_id;
end; $$;
revoke all on function public.release_whatsapp_chat(text) from public;
grant execute on function public.release_whatsapp_chat(text) to authenticated;

-- Agendamento sem conta (vindo da URA, igual ao "Encaixe" feito pelo balcão) não tem
-- clients.id — clients.id tem FK pra auth.users, não dá pra criar um perfil só com telefone.
-- Guarda o telefone direto no agendamento pra confirmação automática funcionar mesmo assim.
alter table public.appointments add column if not exists client_phone text;

-- Confirmação automática pro cliente quando o BARBEIRO aceita (pendente -> confirmado), não
-- importa de onde veio o agendamento (site, balcão ou URA). Só manda se der pra achar telefone:
-- primeiro por client_id -> clients.phone (conta de verdade), senão usa NEW.client_phone direto
-- (agendamento sem conta). Sem telefone nenhum, fica quieto, não quebra nada. O texto vem de
-- whatsapp_ura_settings pra equipe poder editar sem depender de mim.
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

drop trigger if exists trg_notify_appointment_confirmed on appointments;
create trigger trg_notify_appointment_confirmed
  after update on appointments
  for each row execute function notify_appointment_confirmed();
