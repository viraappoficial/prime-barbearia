-- P1-d — Marcar notificações do cliente como lidas.
--
-- Furo hoje: `notifications_update_own` (`USING`, SEM `WITH CHECK`) cobre
-- cliente E staff na MESMA policy — o cliente pode reescrever `text`/
-- `type`/`payload`/`appt_id` das próprias notificações via PostgREST
-- direto (não só marcar `read`), e pode até "des-ler" (`read: true→false`).
--
-- Por que o grant de `authenticated` continua AMPLO (mesmo raciocínio da
-- P1-a): o staff/legado (`primeMarkAllNotifsRead('barber', …)` e o fluxo
-- de "plano-confirmado", index.html l.8344) manda `type`/`text`/`read`
-- juntos numa notificação `for_role='barber'` própria. Grant por coluna
-- é checado ANTES do trigger — `grant update (read)` rejeitaria essa
-- escrita legítima do staff na hora. A barreira real é o trigger, que
-- distingue cliente de staff por `barber_role()`.
--
-- `_notifications_guard_update` NÃO é opcional — é a única coisa que
-- limita o cliente (o grant amplo não impede nada sozinho).
--
-- Rollback:
--   drop trigger notifications_guard_update on public.notifications;
--   drop function public._notifications_guard_update();
--   drop function public.client_mark_notifications_read(bigint[]);
--   grant update on public.notifications to anon;
-- Impacto no legado: nenhum no fluxo normal — `primeMarkAllNotifsRead`
-- (cliente e staff) e o "plano-confirmado" continuam passando (mudança
-- permitida pelo guard). Só uma escrita fora do vocabulário de cada
-- papel passa a ser rejeitada.

revoke update on public.notifications from anon;

-- ── guard: cliente só marca a PRÓPRIA notificação como lida (false→true);
--    staff passa sem restrição (grant amplo, sem cutover ainda) ──────────
create or replace function public._notifications_guard_update()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_changed text[];
begin
  if tg_op <> 'UPDATE' then
    return new;
  end if;

  if current_user in ('postgres', 'supabase_admin', 'service_role') then
    return new;
  end if;

  -- staff (barbeiro/admin/vendas): sem restrição deste guard — continua
  -- valendo o vocabulário do #barberApp (type/text/read juntos, l.8344).
  if public.barber_role() is not null then
    return new;
  end if;

  -- delta DINÂMICO: qualquer coluna cujo valor mudou de fato (inclui
  -- coluna futura → default-deny), mesmo padrão dos outros guards.
  v_changed := array(
    select k
    from jsonb_each(to_jsonb(new)) as n(k, v)
    where n.v is distinct from (to_jsonb(old) -> n.k)
  );
  if cardinality(v_changed) = 0 then
    return new;
  end if;

  -- cliente: só mexe na PRÓPRIA notificação for_role='client' — a RLS já
  -- garante isso via recipient_client_id = auth.uid() antes do trigger
  -- rodar; redundante aqui por defesa em profundidade.
  if old.for_role <> 'client' or old.recipient_client_id is distinct from auth.uid() then
    raise exception 'NOTIF_IMMUTABLE' using errcode = 'P0001';
  end if;

  -- allow-list: só `read`, default-deny pra qualquer outra coluna
  -- (inclusive coluna futura).
  if not (v_changed <@ array['read']) then
    raise exception 'NOTIF_IMMUTABLE' using errcode = 'P0001';
  end if;

  -- só false → true (nunca "des-ler").
  if old.read is distinct from false or new.read is distinct from true then
    raise exception 'NOTIF_READ_ONLY_FORWARD' using errcode = 'P0001';
  end if;

  return new;
end;
$$;

revoke execute on function public._notifications_guard_update()
  from public, anon, authenticated, service_role;

drop trigger if exists notifications_guard_update on public.notifications;
create trigger notifications_guard_update
  before update on public.notifications
  for each row execute function public._notifications_guard_update();

-- ── RPC: client_mark_notifications_read ─────────────────────────────────
-- devolve a contagem marcada (a UI usa pra atualizar o badge sem recarregar
-- a lista inteira). `p_ids = null` marca TODAS as não lidas do cliente
-- (mesmo comportamento do legado `primeMarkAllNotifsRead`).
create or replace function public.client_mark_notifications_read(p_ids bigint[] default null)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_count int;
begin
  if v_uid is null then
    raise exception 'NOT_AUTH' using errcode = 'P0001';
  end if;
  if public.barber_role() is not null then
    raise exception 'NOT_CLIENT' using errcode = 'P0001';
  end if;

  update public.notifications
    set read = true
    where for_role = 'client'
      and recipient_client_id = v_uid
      and read = false
      and (p_ids is null or id = any(p_ids));
  get diagnostics v_count = row_count;

  return v_count;
end;
$$;

revoke execute on function public.client_mark_notifications_read(bigint[])
  from public, anon, authenticated, service_role;
grant execute on function public.client_mark_notifications_read(bigint[])
  to authenticated;
