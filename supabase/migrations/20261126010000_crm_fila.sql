-- CRM: fila de envios programados ("gota a gota"). A equipe escolhe vários clientes, o app reparte os envios ao longo dos dias
-- (9h às 19h, sem domingo) e este agendador solta as mensagens aos poucos, respeitando um limite diário. Cada mensagem liberada
-- vira uma linha pendente em whatsapp_messages (origem 'crm') e o bot envia com as proteções do número, como no envio avulso.
-- Rollback: select cron.unschedule('crm-liberar-fila'); drop function public.crm_liberar_fila(); drop function public.crm_config(); drop table public.crm_fila;
create table if not exists public.crm_fila (
  id bigint generated always as identity primary key,
  lote uuid not null,
  chave text not null,
  phone text not null,
  client_name text not null,
  modelo text,
  body text not null,
  agendado_para timestamptz not null,
  status text not null default 'agendado' check (status in ('agendado','liberado','cancelado')),
  mensagem_id bigint,
  liberado_em timestamptz,
  barber_id uuid not null default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists crm_fila_status_idx on public.crm_fila (status, agendado_para);
create index if not exists crm_fila_lote_idx on public.crm_fila (lote);
alter table public.crm_fila enable row level security;

drop policy if exists crm_fila_staff_read on public.crm_fila;
create policy crm_fila_staff_read on public.crm_fila for select to authenticated
  using (exists (select 1 from public.barbers b where b.id = auth.uid()));
drop policy if exists crm_fila_staff_insert on public.crm_fila;
create policy crm_fila_staff_insert on public.crm_fila for insert to authenticated
  with check (barber_id = auth.uid() and status = 'agendado' and exists (select 1 from public.barbers b where b.id = auth.uid()));
-- a equipe só pode CANCELAR o que ainda não saiu (o resto é do agendador)
drop policy if exists crm_fila_staff_update on public.crm_fila;
create policy crm_fila_staff_update on public.crm_fila for update to authenticated
  using (status = 'agendado' and exists (select 1 from public.barbers b where b.id = auth.uid()))
  with check (status = 'cancelado');

insert into public.whatsapp_ura_settings (key, value) values ('crm_limite_dia', '6') on conflict (key) do nothing;

-- limite diário e quanto já foi programado para hoje (o app usa para repartir os envios)
create or replace function public.crm_config() returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'limite_dia', coalesce((select nullif(value, '')::int from public.whatsapp_ura_settings where key = 'crm_limite_dia'), 6),
    'usado_hoje', (select count(*) from public.crm_fila where status in ('agendado','liberado') and (agendado_para at time zone 'America/Sao_Paulo')::date = (now() at time zone 'America/Sao_Paulo')::date)
  );
$$;
revoke all on function public.crm_config() from public, anon;
grant execute on function public.crm_config() to authenticated;

-- solta as mensagens que já chegaram na hora: no máximo 2 por hora e o limite do dia, só das 9h às 19h e nunca no domingo
create or replace function public.crm_liberar_fila() returns integer language plpgsql security definer set search_path = public as $$
declare
  r record; n int := 0; msg_id bigint;
  sp timestamp := now() at time zone 'America/Sao_Paulo';
  limite int; hoje int; ultima_hora int;
begin
  if extract(hour from sp) < 9 or extract(hour from sp) >= 19 or extract(dow from sp) = 0 then return 0; end if;
  select coalesce((select nullif(value, '')::int from public.whatsapp_ura_settings where key = 'crm_limite_dia'), 6) into limite;
  select count(*) into hoje from public.crm_fila where status = 'liberado' and (liberado_em at time zone 'America/Sao_Paulo')::date = sp::date;
  select count(*) into ultima_hora from public.crm_fila where status = 'liberado' and liberado_em > now() - interval '1 hour';
  for r in select * from public.crm_fila where status = 'agendado' and agendado_para <= now() order by agendado_para limit 2 for update skip locked loop
    exit when hoje + n >= limite or ultima_hora + n >= 2;
    insert into public.whatsapp_messages (chat_id, contact_phone, direction, status, body, origem)
      values ('55' || r.phone || '@c.us', '55' || r.phone, 'outbound', 'pending', r.body, 'crm') returning id into msg_id;
    insert into public.crm_contatos (phone, client_name, barber_id, modelo) values (r.phone, r.client_name, r.barber_id, r.modelo);
    update public.crm_fila set status = 'liberado', liberado_em = now(), mensagem_id = msg_id where id = r.id;
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke all on function public.crm_liberar_fila() from public, anon, authenticated;

select cron.unschedule(jobid) from cron.job where jobname = 'crm-liberar-fila';
select cron.schedule('crm-liberar-fila', '*/2 * * * *', $$select public.crm_liberar_fila()$$);
