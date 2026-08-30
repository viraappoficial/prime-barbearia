-- ST-H.4 — RPCs de transição de status de staff (núcleo da ST-1).
--
-- A Prime Next (ST-1+) NUNCA faz `.from('appointments').update()` de staff —
-- chama estas RPCs. Núcleo SEPARADO do cliente (D2): conjuntos disjuntos.
-- Cada uma: SECURITY DEFINER, `search_path=''`, objetos `public.` qualificados,
-- autoriza por `auth.uid()` + `public.barber_role()`, valida a transição, cria a
-- notificação NA MESMA TRANSAÇÃO (nunca WhatsApp/push/e-mail), sem SQL dinâmico.
--
-- O guard de coluna (ST-H.3) é BYPASSADO aqui: a RPC roda como owner (postgres)
-- → `current_user = 'postgres'` → passo 1 do trigger → `return new`. A validação
-- é toda interna à RPC (Gate 0 §5.3-bis / SH13 / SH26).
--
-- Escopo ST-H (D-H2): SÓ status — accept / start / undo_start / no_show /
-- cancel. `reschedule` e `book_encaixe` → ST-1 (a UI deles vive lá).
-- `complete` + checkout → ST-2.
--
-- Autorização:
--   accept / start / undo_start / no_show : dono (appointments.barber_id =
--     auth.uid()) OU admin OU vendas.
--   cancel                               : dono OU admin (NÃO vendas — D4).
--   `NOT_FOUND` quando a linha não existe OU não é do chamador (não vaza posse).
--
-- Erros de domínio (padrão da agenda: `raise … using errcode='P0001'`):
--   NOT_AUTH, NOT_STAFF, NOT_FOUND, BAD_TRANSITION, ALREADY_STARTED.
--
-- Rollback (as 5 RPCs primeiro — dependem do helper — depois o helper):
--   drop function public.staff_accept_appointment(bigint);
--   drop function public.staff_start_appointment(bigint);
--   drop function public.staff_undo_start(bigint);
--   drop function public.staff_no_show(bigint);
--   drop function public.staff_cancel_appointment(bigint, text);
--   drop function public._staff_appt_for_write(bigint, boolean);
-- Impacto no legado: nenhum. Funções novas; o `#barberApp` segue no UPDATE
-- direto (que a ST-H.3 mantém liberado p/ staff nas colunas operacionais).

-- ── helper interno: resolve appt + valida posse/papel ────────────────────────
-- Não é RPC: SECURITY DEFINER, sem grant a role externa (só o owner chama, de
-- dentro das RPCs abaixo).
create or replace function public._staff_appt_for_write(p_id bigint, p_allow_vendas boolean)
returns public.appointments
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_role text;
  v_appt public.appointments%rowtype;
begin
  if v_uid is null then
    raise exception 'NOT_AUTH' using errcode = 'P0001';
  end if;

  v_role := public.barber_role();
  if v_role is null then
    raise exception 'NOT_STAFF' using errcode = 'P0001';
  end if;

  select * into v_appt from public.appointments where id = p_id;
  if not found then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;

  -- dono sempre; admin sempre; vendas só quando a operação permite
  if not (
       v_appt.barber_id = v_uid
    or v_role = 'admin'
    or (p_allow_vendas and v_role = 'vendas')
  ) then
    raise exception 'NOT_FOUND' using errcode = 'P0001';  -- não vaza posse alheia
  end if;

  return v_appt;
end;
$$;

revoke execute on function public._staff_appt_for_write(bigint, boolean)
  from public, anon, authenticated, service_role;

-- ── staff_accept_appointment — pendente → confirmado + notif ao cliente ──────
create or replace function public.staff_accept_appointment(p_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_appt public.appointments%rowtype := public._staff_appt_for_write(p_id, true);
begin
  if v_appt.status <> 'pendente' then
    raise exception 'BAD_TRANSITION' using errcode = 'P0001';
  end if;

  update public.appointments set status = 'confirmado' where id = p_id;

  if v_appt.client_id is not null then
    insert into public.notifications
      (for_role, recipient_client_id, type, appt_id, text)
    values
      ('client', v_appt.client_id, 'confirmado', p_id,
       'Seu horário de ' || v_appt.day_label || ' às ' || v_appt.time
       || ' foi confirmado pelo barbeiro. Te espero!');
  end if;
end;
$$;

-- ── staff_start_appointment — confirmado & iniciado_em null → seta iniciado_em ─
create or replace function public.staff_start_appointment(p_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_appt public.appointments%rowtype := public._staff_appt_for_write(p_id, true);
begin
  if v_appt.status <> 'confirmado' then
    raise exception 'BAD_TRANSITION' using errcode = 'P0001';
  end if;
  if v_appt.iniciado_em is not null then
    raise exception 'ALREADY_STARTED' using errcode = 'P0001';
  end if;

  update public.appointments set iniciado_em = now() where id = p_id;
end;
$$;

-- ── staff_undo_start — janela de graça: iniciado_em → null ───────────────────
create or replace function public.staff_undo_start(p_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_appt public.appointments%rowtype := public._staff_appt_for_write(p_id, true);
begin
  if v_appt.iniciado_em is null then
    raise exception 'BAD_TRANSITION' using errcode = 'P0001';  -- nada pra desfazer
  end if;

  update public.appointments set iniciado_em = null where id = p_id;
end;
$$;

-- ── staff_no_show — {pendente,confirmado} → nao_compareceu (sem notif) ───────
create or replace function public.staff_no_show(p_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_appt public.appointments%rowtype := public._staff_appt_for_write(p_id, true);
begin
  if v_appt.status not in ('pendente', 'confirmado') then
    raise exception 'BAD_TRANSITION' using errcode = 'P0001';
  end if;

  update public.appointments set status = 'nao_compareceu' where id = p_id;
  -- sem notificação: não faz sentido avisar quem não compareceu (legado idem).
end;
$$;

-- ── staff_cancel_appointment — {pendente,confirmado} → cancelado + notif ─────
create or replace function public.staff_cancel_appointment(p_id bigint, p_motivo text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_appt   public.appointments%rowtype := public._staff_appt_for_write(p_id, false);  -- vendas NÃO (D4)
  v_motivo text := nullif(btrim(coalesce(p_motivo, '')), '');
begin
  if v_appt.status not in ('pendente', 'confirmado') then
    raise exception 'BAD_TRANSITION' using errcode = 'P0001';
  end if;

  update public.appointments set status = 'cancelado' where id = p_id;

  if v_appt.client_id is not null then
    insert into public.notifications
      (for_role, recipient_client_id, type, appt_id, text)
    values
      ('client', v_appt.client_id, 'cancelado-barbeiro', p_id,
       'Seu horário de ' || v_appt.day_label || ' às ' || v_appt.time
       || ' foi cancelado pelo barbeiro.'
       || case when v_motivo is not null then ' Motivo: ' || v_motivo || '.' else '' end
       || ' Toque aqui para reagendar.');
  end if;
end;
$$;

-- ── grants ──────────────────────────────────────────────────────────────────
-- default privileges do Supabase concedem EXECUTE a anon/authenticated/
-- service_role; normalizar para authenticated (as RPCs checam o papel por
-- dentro — NUNCA anon).
revoke execute on function public.staff_accept_appointment(bigint)
  from public, anon, authenticated, service_role;
revoke execute on function public.staff_start_appointment(bigint)
  from public, anon, authenticated, service_role;
revoke execute on function public.staff_undo_start(bigint)
  from public, anon, authenticated, service_role;
revoke execute on function public.staff_no_show(bigint)
  from public, anon, authenticated, service_role;
revoke execute on function public.staff_cancel_appointment(bigint, text)
  from public, anon, authenticated, service_role;

grant execute on function public.staff_accept_appointment(bigint)  to authenticated;
grant execute on function public.staff_start_appointment(bigint)   to authenticated;
grant execute on function public.staff_undo_start(bigint)          to authenticated;
grant execute on function public.staff_no_show(bigint)             to authenticated;
grant execute on function public.staff_cancel_appointment(bigint, text) to authenticated;
