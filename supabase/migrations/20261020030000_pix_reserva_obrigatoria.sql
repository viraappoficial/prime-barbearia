-- Pix online: interruptor (começa DESLIGADO), reserva de 30 min em datas de pagamento obrigatório (só cliente do site) e expiração completa.
-- Aplicada e testada no banco em 2026-10-20 (cenários: obrigatório, fora da regra, bot/equipe, interruptor desligado, reserva vencida).

create table if not exists public.payment_settings (
  id boolean primary key default true check (id),
  online_pix_enabled boolean not null default false,
  updated_at timestamptz not null default now()
);
insert into public.payment_settings (id) values (true) on conflict do nothing;
alter table public.payment_settings enable row level security;
grant select on public.payment_settings to anon, authenticated;
grant update on public.payment_settings to authenticated;
drop policy if exists payment_settings_public_read on public.payment_settings;
create policy payment_settings_public_read on public.payment_settings for select using (true);
drop policy if exists payment_settings_admin_update on public.payment_settings;
create policy payment_settings_admin_update on public.payment_settings for update
  using (exists (select 1 from barbers b where b.id = auth.uid() and b.role = 'admin'))
  with check (exists (select 1 from barbers b where b.id = auth.uid() and b.role = 'admin'));

-- Só agendamento feito PELO CLIENTE no site (anon ou conta de cliente) reserva o horário por 30 min em data obrigatória.
-- Equipe (balcão, encaixe) e bot (service_role) não passam por aqui.
create or replace function public._appointment_payment_reserve()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce((select online_pix_enabled from payment_settings limit 1), false)
     and NEW.status = 'pendente' and NEW.payment_status = 'nenhum'
     and auth.role() in ('anon', 'authenticated')
     and not exists (select 1 from barbers b where b.id = auth.uid())
     and public.payment_required_for(NEW.day) then
    NEW.payment_status := 'pendente';
    NEW.reserved_until := now() + interval '30 minutes';
  end if;
  return NEW;
end;
$$;
drop trigger if exists appointments_payment_reserve on public.appointments;
create trigger appointments_payment_reserve before insert on public.appointments
  for each row execute function public._appointment_payment_reserve();

create or replace function public.expirar_pagamentos_pix()
returns integer language plpgsql security definer set search_path = public as $$
declare r record; n integer := 0; m integer := 0;
begin
  -- 1) Pix gerado e não pago a tempo: vence; em data obrigatória cancela o agendamento (libera o horário)
  for r in
    select p.id, p.appointment_id from appointment_payments p
    where p.status = 'pendente' and p.expires_at < now()
    for update skip locked
  loop
    update appointment_payments set status = 'vencido' where id = r.id;
    update appointments a set payment_status = 'nenhum', reserved_until = null where a.id = r.appointment_id;
    update appointments a set status = 'cancelado'
      where a.id = r.appointment_id and a.status = 'pendente' and payment_required_for(a.day);
    n := n + 1;
  end loop;
  -- 2) Data obrigatória reservada por 30 min e nenhum Pix pago nesse tempo (nem chegou a gerar): cancela
  update appointments a set status = 'cancelado', payment_status = 'nenhum', reserved_until = null
    where a.status = 'pendente' and a.payment_status = 'pendente' and a.reserved_until is not null and a.reserved_until < now()
      and payment_required_for(a.day)
      and not exists (select 1 from appointment_payments p where p.appointment_id = a.id and p.status = 'aprovado');
  get diagnostics m = row_count;
  return n + m;
end;
$$;
