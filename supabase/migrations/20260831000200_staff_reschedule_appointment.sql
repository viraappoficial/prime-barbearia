-- ST-1b.2 — remarcar agendamento pelo STAFF (in-place funcional: novo id +
-- cancela o antigo, atômico).
--
-- Legado: `baConfirmRemarcar` faz `UPDATE {day, day_label, time}` direto — mesmo
-- barbeiro, mesmos serviços, mesmo status, SEM revalidar escala/sobreposição.
-- Esta RPC:
--   1. valida posse/papel + status remarcável (`_staff_appt_for_write` — vendas
--      incluído: remarcar preserva o agendamento, não é cancelamento);
--   2. resolve a duração da linha antiga (a ST-1b.0 backfillou os ativos; se
--      ainda NULL → deriva do catálogo só se TODOS os serviços resolverem, senão
--      `OVERLAP_UNCHECKED` — nunca fallback);
--   3. **cancela o antigo NA MESMA TRANSAÇÃO** — assim ele sai do índice parcial
--      e da checagem manual, e mover o agendamento um slot não colide com ele
--      mesmo. Se o passo 4 falhar → `raise` → ROLLBACK de tudo → o antigo volta
--      intacto (atomicidade pela transação, não pela ordem);
--   4. cria o novo via `_staff_insert_appointment` — mesmos barbeiro / serviços
--      (nomes) / duração / cliente / status / notes / is_encaixe da linha
--      antiga. O browser mandou SÓ `p_id`, `p_day`, `p_time`;
--   5. notifica o cliente (`remarcado`) na transação — só se conta (walk-in não
--      tem conta).
--
-- NÃO muda o barbeiro (o modal do legado não tem seletor). NÃO edita serviços
-- (isso é "editar atendimento" — outra fatia). NÃO abre WhatsApp (a notif in-app
-- é o canal — igual à ST-1a).
--
-- `SECURITY DEFINER`, `search_path=''`. `revoke execute` de todos → `grant` só a
-- `authenticated` (o papel é checado por dentro).
--
-- Rollback: drop function public.staff_reschedule_appointment(bigint, date, text);
-- Impacto no legado: nenhum — o `#barberApp` segue no UPDATE direto (o guard da
-- ST-H libera `day`/`day_label`/`time` para staff).

create or replace function public.staff_reschedule_appointment(
  p_id   bigint,
  p_day  date,
  p_time text
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old        public.appointments%rowtype;
  v_dur        int;
  v_resolvidos int;
  v_new_id     bigint;
  v_new        public.appointments%rowtype;
begin
  -- 1. posse/papel + linha (vendas incluído — D-1b-1)
  v_old := public._staff_appt_for_write(p_id, true);

  -- 2. só remarca agendamento ATIVO e não iniciado (paridade: canManage exige
  --    !em_andamento)
  if v_old.status not in ('pendente', 'confirmado') or v_old.iniciado_em is not null then
    raise exception 'NOT_RESCHEDULABLE' using errcode = 'P0001';
  end if;

  -- 3. duração da linha antiga — nunca NULL na sobreposição, nunca fallback
  if v_old.duration is not null then
    v_dur := v_old.duration;
  else
    select count(*) into v_resolvidos
    from public.services s where s.name = any(v_old.services);
    if coalesce(cardinality(v_old.services), 0) = v_resolvidos and v_resolvidos > 0 then
      select sum(s.duration_min) into v_dur
      from public.services s where s.name = any(v_old.services);
    else
      raise exception 'OVERLAP_UNCHECKED' using errcode = 'P0001';
    end if;
  end if;

  -- 4. cancela o antigo AGORA (dentro da transação) — sai da checagem do núcleo
  update public.appointments set status = 'cancelado' where id = p_id;

  -- 5. cria o novo — tudo herdado de v_old; browser só mandou p_id/p_day/p_time
  v_new_id := public._staff_insert_appointment(
    p_barber_id     => v_old.barber_id,          -- mesmo barbeiro (D-1b-2)
    p_day           => p_day,
    p_time          => p_time,
    p_service_names => v_old.services,            -- nomes da linha antiga
    p_duration      => v_dur,                     -- passo 3
    p_client_id     => v_old.client_id,
    p_client_name   => v_old.client_name,
    p_client_email  => v_old.client_email,
    p_is_encaixe    => v_old.is_encaixe,          -- encaixe remarcado continua encaixe
    p_status        => v_old.status,              -- preserva (D-1b-3)
    p_notes         => v_old.notes,
    p_grid_aligned  => not v_old.is_encaixe       -- reschedule normal = grade; encaixe = off-grid
  );

  -- 6. notifica o cliente — só se conta (walk-in não tem)
  if v_old.client_id is not null then
    select * into v_new from public.appointments where id = v_new_id;
    insert into public.notifications
      (for_role, recipient_client_id, type, appt_id, text)
    values
      ('client', v_old.client_id, 'remarcado', v_new_id,
       'Seu horário de ' || v_old.day_label || ' às ' || v_old.time
       || ' foi remarcado para ' || v_new.day_label || ' às ' || p_time || '.');
  end if;

  return v_new_id;
end;
$$;

revoke execute on function public.staff_reschedule_appointment(bigint, date, text)
  from public, anon, authenticated, service_role;
grant execute on function public.staff_reschedule_appointment(bigint, date, text)
  to authenticated;
