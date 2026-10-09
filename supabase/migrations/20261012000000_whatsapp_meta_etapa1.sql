-- Etapa 1 da API oficial do WhatsApp (Cloud API da Meta) — SÓ ACRESCENTA, não muda o fluxo atual (WAHA).
--
-- 1) whatsapp_channels — um canal por número/provedor ('waha' = o de hoje, 'meta' = oficial). O token da
--    Meta NÃO fica aqui: fica em variável de ambiente do servidor.
-- 2) whatsapp_meta_events — caixa de entrada crua do webhook da Meta. A Edge Function só grava aqui e
--    responde 200; quem processa é o servidor do bot (assim webhook nunca cai por causa do servidor de casa).
-- 3) whatsapp_messages — colunas novas: canal, id da mensagem no provedor (dedup), tipo (texto/modelo),
--    modelo e parâmetros, motivo de espera e código de erro. Novo status 'held' (em espera, visível no Zap).
-- 4) whatsapp_contacts.last_inbound_at — base da janela de 24 h.
-- 5) whatsapp_optin — registro de que o cliente pediu contato (ao agendar), com data e canal; opt-out.
-- 6) trigger em appointments — grava o opt-in ao agendar; erro aqui é engolido (agendar nunca falha por isso).
--
-- Rollback:
--   drop trigger appointments_whatsapp_optin on public.appointments;
--   drop function public._whatsapp_optin_on_insert();
--   drop table public.whatsapp_optin, public.whatsapp_meta_events;
--   alter table public.whatsapp_contacts drop column last_inbound_at;
--   alter table public.whatsapp_messages drop column channel_id, drop column provider_msg_id, drop column kind,
--     drop column template_name, drop column template_lang, drop column template_params,
--     drop column hold_reason, drop column error_code;
--   (e recriar o check de status sem 'held')
--   drop table public.whatsapp_channels;

create table if not exists public.whatsapp_channels (
  id              uuid primary key default gen_random_uuid(),
  provider        text not null check (provider in ('waha', 'meta')),
  name            text not null,
  display_phone   text,
  phone_number_id text unique,
  waba_id         text,
  active          boolean not null default true,
  created_at      timestamptz not null default now()
);
alter table public.whatsapp_channels enable row level security;
revoke all on public.whatsapp_channels from public, anon, authenticated;

create table if not exists public.whatsapp_meta_events (
  id           bigint generated always as identity primary key,
  received_at  timestamptz not null default now(),
  payload      jsonb not null,
  processed_at timestamptz,
  error        text
);
create index if not exists whatsapp_meta_events_unprocessed_idx on public.whatsapp_meta_events (id) where processed_at is null;
alter table public.whatsapp_meta_events enable row level security;
revoke all on public.whatsapp_meta_events from public, anon, authenticated;

alter table public.whatsapp_messages
  add column if not exists channel_id      uuid references public.whatsapp_channels(id),
  add column if not exists provider_msg_id text,
  add column if not exists kind            text not null default 'text',
  add column if not exists template_name   text,
  add column if not exists template_lang   text,
  add column if not exists template_params jsonb,
  add column if not exists hold_reason     text,
  add column if not exists error_code      text;

alter table public.whatsapp_messages drop constraint if exists whatsapp_messages_kind_check;
alter table public.whatsapp_messages add constraint whatsapp_messages_kind_check check (kind in ('text', 'template'));

alter table public.whatsapp_messages drop constraint if exists whatsapp_messages_status_check;
alter table public.whatsapp_messages add constraint whatsapp_messages_status_check
  check (status in ('received', 'pending', 'sent', 'failed', 'held'));

create unique index if not exists whatsapp_messages_provider_msg_id_key
  on public.whatsapp_messages (provider_msg_id) where provider_msg_id is not null;
create index if not exists whatsapp_messages_channel_pending_idx
  on public.whatsapp_messages (channel_id, created_at) where status = 'pending';

alter table public.whatsapp_contacts add column if not exists last_inbound_at timestamptz;

create table if not exists public.whatsapp_optin (
  phone         text primary key,           -- só dígitos, com DDI (ex.: 554499445716)
  opted_in_at   timestamptz not null default now(),
  source        text not null default 'agendamento',
  channel       text,
  opted_out_at  timestamptz
);
alter table public.whatsapp_optin enable row level security;
revoke all on public.whatsapp_optin from public, anon, authenticated;

create or replace function public._whatsapp_optin_on_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_raw    text;
  v_digits text;
  -- mesma regra do telefone usada na confirmação ao cliente (DDD válido da Anatel; +/00 = internacional)
  v_ddds   text[] := array['11','12','13','14','15','16','17','18','19','21','22','24','27','28','31','32','33','34','35','37','38','41','42','43','44','45','46','47','48','49','51','53','54','55','61','62','63','64','65','66','67','68','69','71','73','74','75','77','79','81','82','83','84','85','86','87','88','89','91','92','93','94','95','96','97','98','99'];
begin
  begin
    if new.client_id is not null then
      select c.phone into v_raw from public.clients c where c.id = new.client_id;
      v_digits := regexp_replace(coalesce(v_raw, ''), '\D', '', 'g');
      if v_digits <> '' then
        if v_raw ~ '^\s*(\+|00)' then
          v_digits := regexp_replace(v_digits, '^00', '');      -- internacional de propósito: nunca recebe o 55
        else
          v_digits := regexp_replace(v_digits, '^0+', '');      -- zero de tronco
          if substr(v_digits, 1, 2) = any (v_ddds)
             and ((length(v_digits) = 11 and substr(v_digits, 3, 1) = '9')
                  or (length(v_digits) = 10 and substr(v_digits, 3, 1) between '2' and '9')) then
            v_digits := '55' || v_digits;
          end if;
        end if;
        if length(v_digits) >= 11 then
          insert into public.whatsapp_optin (phone, source) values (v_digits, 'agendamento') on conflict (phone) do nothing;
        end if;
      end if;
    end if;
  exception when others then
    null; -- nunca atrapalha o agendamento
  end;
  return new;
end;
$$;
revoke all on function public._whatsapp_optin_on_insert() from public, anon, authenticated;

drop trigger if exists appointments_whatsapp_optin on public.appointments;
create trigger appointments_whatsapp_optin after insert on public.appointments
  for each row execute function public._whatsapp_optin_on_insert();
