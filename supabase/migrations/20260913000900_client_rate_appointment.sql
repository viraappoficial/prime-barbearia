-- P1-c — Avaliação one-shot de corte. RPC `client_rate_appointment`.
--
-- O guard `_appointments_guard_update` (ST-H.3, D-H9, já aplicado no lab em
-- `20260830000250_appointments_guard_hybrid.sql`) já barra re-avaliação e
-- valores fora de 1..5 mesmo num PATCH direto do cliente — esta RPC é o
-- caminho oficial: faz a MESMA validação (defesa em profundidade, mensagens
-- de erro previsíveis por allowlist) e, na mesma transação, insere a
-- notificação pro barbeiro (o guard não faz side-effect nenhum, só valida).
--
-- Ordem de validação (igual à proposta, `docs/investigacoes/07-p1-...md` §4):
--   1. NOT_FOUND       — não existe ou não é do cliente (não vaza posse)
--   2. NOT_COMPLETED   — status <> 'concluido'
--   3. ALREADY_RATED   — rating já setado (one-shot, D-P1-1)
--   4. BAD_RATING      — p_rating fora de 1..5 (ou null)
--
-- Rollback:
--   drop function public.client_rate_appointment(bigint, int, text);
-- Impacto no legado: nenhum — `caFinishAppointment`/`primeUpdateAppointment`
-- continuam fazendo PATCH direto, e o guard da ST-H.3 já valida esse caminho
-- (one-shot, 1..5, só o próprio corte concluído). Esta RPC é só o caminho
-- novo do Next, que soma a notificação ao barbeiro na mesma transação.

create or replace function public.client_rate_appointment(p_id bigint, p_rating int, p_comment text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_appt public.appointments%rowtype;
begin
  if v_uid is null then
    raise exception 'NOT_AUTH' using errcode = 'P0001';
  end if;
  if public.barber_role() is not null then
    raise exception 'NOT_CLIENT' using errcode = 'P0001';
  end if;

  select * into v_appt from public.appointments where id = p_id and client_id = v_uid;
  if not found then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
  if v_appt.status <> 'concluido' then
    raise exception 'NOT_COMPLETED' using errcode = 'P0001';
  end if;
  if v_appt.rating is not null then
    raise exception 'ALREADY_RATED' using errcode = 'P0001';
  end if;
  if p_rating is null or p_rating < 1 or p_rating > 5 then
    raise exception 'BAD_RATING' using errcode = 'P0001';
  end if;

  update public.appointments
    set rating = p_rating,
        rating_comment = nullif(trim(coalesce(p_comment, '')), ''),
        rating_by = 'cliente'
    where id = p_id;

  insert into public.notifications (for_role, recipient_barber_id, type, appt_id, text)
    values ('barber', v_appt.barber_id, 'avaliacao', p_id,
            format('Você recebeu uma avaliação de %s estrela(s)', p_rating));
end;
$$;

revoke execute on function public.client_rate_appointment(bigint, int, text)
  from public, anon, authenticated, service_role;
grant execute on function public.client_rate_appointment(bigint, int, text)
  to authenticated;
