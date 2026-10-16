-- Evolution (WhatsApp por QR) como canal PRINCIPAL de saída e entrada, no lugar da WAHA (aposentada).
--   1) libera 'evolution' como tipo de canal em whatsapp_channels;
--   2) cria o canal (uma vez) e o define como canal padrão das mensagens que nascem no banco / no Zap do app
--      (whatsapp_ura_settings.default_outbound_channel) — resposta da equipe, aviso ao barbeiro, confirmação ao cliente.
-- Idempotente: pode rodar de novo sem duplicar. Não apaga nada.
-- Impacto: mensagens pendentes SEM canal passam a sair pelo Evolution (o servidor do bot na VPS é quem envia).
-- Reverter (se precisar): delete from whatsapp_ura_settings where key = 'default_outbound_channel';
--   update whatsapp_channels set active = false where provider = 'evolution';

do $$
declare c text;
begin
  for c in
    select conname from pg_constraint
    where conrelid = 'public.whatsapp_channels'::regclass and contype = 'c' and pg_get_constraintdef(oid) ilike '%provider%'
  loop
    execute format('alter table public.whatsapp_channels drop constraint %I', c);
  end loop;
end $$;

alter table public.whatsapp_channels
  add constraint whatsapp_channels_provider_check check (provider in ('waha', 'meta', 'evolution'));

insert into public.whatsapp_channels (provider, name, active)
select 'evolution', 'Evolution (chip principal)', true
where not exists (select 1 from public.whatsapp_channels where provider = 'evolution');

insert into public.whatsapp_ura_settings (key, value)
select 'default_outbound_channel', id::text
from public.whatsapp_channels
where provider = 'evolution'
order by created_at
limit 1
on conflict (key) do update set value = excluded.value, updated_at = now();
