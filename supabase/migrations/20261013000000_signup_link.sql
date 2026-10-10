-- Link de cadastro rápido pra quem agenda pela URA do WhatsApp sem ter conta.
--
-- Fluxo: a URA cria o agendamento (pendente, horário já reservado) marcado `signup_pending`, e manda o link
-- "Para confirmar seu atendimento, entre no link". O cliente abre o link (modal com o resumo do agendamento +
-- cadastro rápido), cadastra, e o agendamento passa a ser dele (client_id). Só nesse momento o barbeiro recebe o
-- aviso — assim, agendamento falso de número que nunca se cadastra não polui o aviso dos barbeiros.
-- O status continua 'pendente' até o barbeiro confirmar (confirmar = ato do barbeiro; o cadastro é o aceite do cliente).
--
-- 1) appointments.signup_pending — agendamento da URA de quem ainda não tem conta.
-- 2) appointment_signup_links — token por agendamento (só o servidor do WhatsApp escreve; navegador nunca lê direto).
-- 3) trigger do aviso ao barbeiro: não cria aviso enquanto signup_pending.
-- 4) signup_link_info(token)   — anônimo: devolve o resumo do agendamento pro modal (o token é o segredo).
-- 5) signup_link_confirm(token) — logado: vincula o agendamento à conta nova e libera o aviso ao barbeiro.
--
-- Rollback:
--   drop function public.signup_link_confirm(text); drop function public.signup_link_info(text);
--   drop table public.appointment_signup_links; alter table public.appointments drop column signup_pending;
--   (e recriar _barber_notice_on_insert sem a condição de signup_pending)
-- Impacto: nenhum no fluxo atual (a coluna nasce false; só a URA nova liga).

alter table public.appointments add column if not exists signup_pending boolean not null default false;

create table if not exists public.appointment_signup_links (
  id             bigint generated always as identity primary key,
  token          text not null unique default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  appointment_id bigint not null unique references public.appointments(id) on delete cascade,
  phone          text not null,                         -- só dígitos, com DDI (o número que falou com o bot)
  created_at     timestamptz not null default now(),
  expires_at     timestamptz not null default now() + interval '3 days',
  used_at        timestamptz,
  client_id      uuid
);
alter table public.appointment_signup_links enable row level security;
revoke all on public.appointment_signup_links from public, anon, authenticated;

create or replace function public._barber_notice_on_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'pendente' and not coalesce(new.is_encaixe, false) and new.barber_id is not null
     and not coalesce(new.signup_pending, false) then
    insert into public.barber_notices (appointment_id, barber_id) values (new.id, new.barber_id)
    on conflict (appointment_id) do nothing;
  end if;
  return new;
exception when others then
  return new;   -- o aviso é secundário: jamais pode impedir o agendamento
end;
$$;
revoke execute on function public._barber_notice_on_insert() from public, anon, authenticated, service_role;

create or replace function public.signup_link_info(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  l public.appointment_signup_links%rowtype;
  a public.appointments%rowtype;
  v_barber text;
begin
  if p_token is null or length(p_token) < 20 then
    return jsonb_build_object('ok', false, 'reason', 'invalid');
  end if;
  select * into l from public.appointment_signup_links where token = p_token;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'invalid');
  end if;
  select * into a from public.appointments where id = l.appointment_id;
  if not found or a.status in ('cancelado', 'nao_compareceu') then
    return jsonb_build_object('ok', false, 'reason', 'cancelled');
  end if;
  if l.used_at is not null then
    return jsonb_build_object('ok', false, 'reason', 'used');
  end if;
  if l.expires_at < now() then
    return jsonb_build_object('ok', false, 'reason', 'expired');
  end if;
  select b.name into v_barber from public.barbers b where b.id = a.barber_id;
  return jsonb_build_object('ok', true, 'phone', l.phone, 'client_name', a.client_name, 'day_label', a.day_label,
                            'time', a.time, 'services', a.services, 'barber', v_barber);
end;
$$;
revoke execute on function public.signup_link_info(text) from public, anon, authenticated, service_role;
grant execute on function public.signup_link_info(text) to anon, authenticated;

create or replace function public.signup_link_confirm(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  l public.appointment_signup_links%rowtype;
  a public.appointments%rowtype;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in');
  end if;
  if p_token is null or length(p_token) < 20 then
    return jsonb_build_object('ok', false, 'reason', 'invalid');
  end if;
  select * into l from public.appointment_signup_links where token = p_token for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'invalid');
  end if;
  select * into a from public.appointments where id = l.appointment_id for update;
  if not found or a.status in ('cancelado', 'nao_compareceu') then
    return jsonb_build_object('ok', false, 'reason', 'cancelled');
  end if;
  if l.used_at is not null then
    return jsonb_build_object('ok', false, 'reason', 'used');
  end if;
  if l.expires_at < now() then
    return jsonb_build_object('ok', false, 'reason', 'expired');
  end if;
  if not exists (select 1 from public.clients c where c.id = auth.uid()) then
    return jsonb_build_object('ok', false, 'reason', 'no_client');
  end if;

  update public.appointments set client_id = auth.uid(), signup_pending = false where id = a.id;
  update public.appointment_signup_links set used_at = now(), client_id = auth.uid() where id = l.id;

  -- só agora o barbeiro é avisado (o aviso foi segurado enquanto o cadastro não saía)
  if a.status = 'pendente' and not coalesce(a.is_encaixe, false) and a.barber_id is not null then
    insert into public.barber_notices (appointment_id, barber_id) values (a.id, a.barber_id)
    on conflict (appointment_id) do nothing;
  end if;
  return jsonb_build_object('ok', true, 'day_label', a.day_label, 'time', a.time, 'services', a.services);
end;
$$;
revoke execute on function public.signup_link_confirm(text) from public, anon, authenticated, service_role;
grant execute on function public.signup_link_confirm(text) to authenticated;
