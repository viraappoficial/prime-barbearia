-- Aviso de novo agendamento pro WhatsApp do barbeiro + link de confirmar com um toque.
--
-- 1) barbers.phone — telefone (só dígitos, com 55) pra onde o bot manda o aviso e de onde reconhece
--    a resposta do barbeiro.
-- 2) barber_notices — um aviso por agendamento novo (pendente, não é encaixe). Quem manda é o
--    servidor do WhatsApp (service_role): lê os avisos ainda não enviados, manda a mensagem,
--    repete de hora em hora até o barbeiro resolver. O navegador nunca lê esta tabela.
-- 3) trigger — cria o aviso quando entra um agendamento. Nunca atrapalha o agendamento: qualquer
--    erro aqui é engolido (o cliente agenda do mesmo jeito).
-- 4) barber_confirm_by_token(token) — o link da mensagem. Token aleatório, vale 7 dias, só
--    confirma (pendente -> confirmado, o que já dispara a confirmação ao cliente pelo WhatsApp).
--    Cancelar/remarcar NÃO é por link: é por resposta no WhatsApp (o número do remetente identifica
--    o barbeiro; um link poderia ser encaminhado).
-- 5) whatsapp_contacts.handoff_requested_at / escalation_stage — base dos avisos de 5 e 10 minutos
--    quando o cliente pede atendente e ninguém assume.
--
-- Rollback:
--   drop trigger appointments_barber_notice on public.appointments;
--   drop function public._barber_notice_on_insert(); drop function public.barber_confirm_by_token(text);
--   drop table public.barber_notices;
--   alter table public.barbers drop column phone;
--   alter table public.whatsapp_contacts drop column handoff_requested_at, drop column escalation_stage;
-- Impacto: nenhum no fluxo atual; só acrescenta.

alter table public.barbers add column if not exists phone text;
alter table public.whatsapp_contacts
  add column if not exists handoff_requested_at timestamptz,
  add column if not exists escalation_stage integer not null default 0;

create table if not exists public.barber_notices (
  id               bigint generated always as identity primary key,
  appointment_id   bigint not null unique references public.appointments(id) on delete cascade,
  barber_id        uuid not null,
  token            text not null unique default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  status           text not null default 'pending' check (status in ('pending', 'confirmed', 'proposed', 'cancelled', 'expired')),
  created_at       timestamptz not null default now(),
  expires_at       timestamptz not null default now() + interval '7 days',
  sent_at          timestamptz,
  reminders_sent   integer not null default 0,
  last_reminder_at timestamptz,
  resolved_at      timestamptz,
  proposed_day     date,
  proposed_time    text
);
alter table public.barber_notices enable row level security;
revoke all on public.barber_notices from public, anon, authenticated;
-- sem policy nenhuma: só o servidor (service_role) lê/escreve; o navegador nunca vê esta tabela

create or replace function public._barber_notice_on_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'pendente' and not coalesce(new.is_encaixe, false) and new.barber_id is not null then
    insert into public.barber_notices (appointment_id, barber_id) values (new.id, new.barber_id)
    on conflict (appointment_id) do nothing;
  end if;
  return new;
exception when others then
  return new;   -- o aviso é secundário: jamais pode impedir o agendamento
end;
$$;
revoke execute on function public._barber_notice_on_insert() from public, anon, authenticated, service_role;

drop trigger if exists appointments_barber_notice on public.appointments;
create trigger appointments_barber_notice
  after insert on public.appointments
  for each row execute function public._barber_notice_on_insert();

create or replace function public.barber_confirm_by_token(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  n public.barber_notices%rowtype;
  a public.appointments%rowtype;
begin
  select * into n from public.barber_notices where token = p_token;
  if not found or p_token is null or length(p_token) < 20 then
    return jsonb_build_object('ok', false, 'reason', 'invalid');
  end if;
  if n.expires_at < now() then
    return jsonb_build_object('ok', false, 'reason', 'expired');
  end if;
  select * into a from public.appointments where id = n.appointment_id;
  if not found or a.status in ('cancelado', 'nao_compareceu') then
    return jsonb_build_object('ok', false, 'reason', 'cancelled');
  end if;
  if a.status = 'pendente' then
    update public.appointments set status = 'confirmado' where id = a.id;
    update public.barber_notices set status = 'confirmed', resolved_at = now() where id = n.id;
    return jsonb_build_object('ok', true, 'already', false, 'client', a.client_name, 'day_label', a.day_label, 'time', a.time, 'services', a.services);
  end if;
  -- já confirmado/concluído por outro caminho (app, resposta no WhatsApp...): não é erro
  update public.barber_notices set status = 'confirmed', resolved_at = coalesce(resolved_at, now()) where id = n.id and status = 'pending';
  return jsonb_build_object('ok', true, 'already', true, 'client', a.client_name, 'day_label', a.day_label, 'time', a.time, 'services', a.services);
end;
$$;
revoke execute on function public.barber_confirm_by_token(text) from public, anon, authenticated, service_role;
grant execute on function public.barber_confirm_by_token(text) to anon, authenticated;
