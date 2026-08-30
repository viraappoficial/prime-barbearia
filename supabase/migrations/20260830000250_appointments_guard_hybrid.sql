-- ST-H.3b — guard de colunas: distinguir "barbeiro operando SUA agenda" de
-- "barbeiro agindo como CLIENTE" (achado da revisão do Codex ao Gate 1).
--
-- ── O furo (provado no lab, guard da 20260830000200) ──
-- Um usuário que é **barbeiro** (`barbers.role='barbeiro'`) E **cliente**
-- (`clients`), com um agendamento PRÓPRIO marcado com OUTRO barbeiro
-- (`client_id = auth.uid()` ∧ `barber_id <> auth.uid()`):
--   • passa no `USING` da RLS por `clients_update_own` (a `barbers_update_own`
--     NÃO se aplica — exige `barber_id = auth.uid()`);
--   • mas `_appointments_guard_update()` escolhia o allow-list por
--     `barber_role()`, que devolve `'barbeiro'` → caía no conjunto de STAFF e
--     podia editar `discount_price`, `services`, `day`/`time`, `notes`, e
--     `status → confirmado` da PRÓPRIA linha — como se fosse o barbeiro do
--     atendimento.
--
-- ── A correção ──
-- O caminho de STAFF operacional só vale quando o barbeiro está de fato na
-- agenda dele: `OLD.barber_id = auth.uid()`. Se `OLD.barber_id <> auth.uid()`,
-- a única forma de ter passado no `USING` foi `clients_update_own` → ele é
-- CLIENTE daquela linha e as regras de cliente valem (cancelar o próprio ativo,
-- avaliar 1× o próprio corte concluído; resto bloqueado).
--
-- `admin` e `vendas` **mantêm** o caminho de staff mesmo na própria linha-como-
-- cliente: as policies `admin_update_all` / `appointments_vendas_update` lhes
-- dão escopo global DELIBERADO (USING `barber_role() = 'admin' | 'vendas'`), sem
-- amarra de posse. Apertar isso seria mudar a intenção do papel — ST-2+.
--
-- ── "barbeiro operando sua agenda" vs "barbeiro agindo como cliente" ──
--   barber_role()='barbeiro' ∧ OLD.barber_id  = auth.uid()  → STAFF operacional
--   barber_role()='barbeiro' ∧ OLD.barber_id <> auth.uid()  → CLIENTE
--   barber_role() is null                                   → CLIENTE
--   barber_role() in ('admin','vendas')                     → STAFF (global)
--
-- As RPCs `SECURITY DEFINER` de staff (`staff_accept/start/undo_start/no_show/
-- cancel`) NÃO mudam: a posse já é checada em `_staff_appt_for_write`
-- (`v_appt.barber_id = auth.uid() OR admin [OR vendas]`) — um híbrido chamando
-- `staff_*` sobre a própria linha-como-cliente recebe `NOT_FOUND`.
--
-- Só recria `_appointments_guard_update()` (o trigger e os grants da
-- 20260830000200 ficam). NÃO altera a migration já aplicada.
--
-- Rollback: reaplicar o corpo de `20260830000200_appointments_col_guard.sql`
--   (a função sem o `v_as_client` — volta a escolher o allow-list só por
--    `barber_role()`). O trigger/grants não mudam.
-- Impacto no legado: nenhum no fluxo normal.
--   • `#barberApp`: o barbeiro na PRÓPRIA agenda continua igual
--     (OLD.barber_id = auth.uid() → STAFF).
--   • `#clientApp`: um barbeiro que também usa o app de cliente para marcar o
--     próprio corte com um colega deixa de conseguir editar preço/serviço/data
--     dessa linha — passa a valer a regra de cliente (que é a correta).

create or replace function public._appointments_guard_update()
returns trigger
language plpgsql
security invoker            -- current_user = o role do request real (Gate 0 §5.3-bis)
set search_path = ''
as $$
declare
  v_role      text;
  v_changed   text[];
  v_as_client boolean;
begin
  if tg_op <> 'UPDATE' then
    return new;
  end if;

  -- caminhos que fazem a própria validação:
  --   postgres       → migrations, seeds, jobs, RPCs SECURITY DEFINER (owner)
  --   supabase_admin → console / admin
  --   service_role   → backend com a chave de serviço
  if current_user in ('postgres', 'supabase_admin', 'service_role') then
    return new;
  end if;

  -- delta DINÂMICO: qualquer coluna cujo valor mudou de fato (inclui coluna
  -- futura → default-deny). Comparação valor a valor via jsonb.
  v_changed := array(
    select k
    from jsonb_each(to_jsonb(new)) as n(k, v)
    where n.v is distinct from (to_jsonb(old) -> n.k)
  );
  if cardinality(v_changed) = 0 then
    return new;
  end if;

  v_role := public.barber_role();

  -- Trata como CLIENTE quando:
  --   • não é staff (barber_role() is null); OU
  --   • é 'barbeiro' MAS esta linha não é da agenda dele (OLD.barber_id <>
  --     auth.uid()) → só chegou aqui por clients_update_own, logo é cliente
  --     da própria linha.
  -- admin/vendas NUNCA entram aqui (escopo global deliberado das suas policies).
  v_as_client := v_role is null
              or (v_role = 'barbeiro' and old.barber_id is distinct from auth.uid());

  if v_as_client then
    -- vocabulário INTEIRO do cliente: {status} + as 3 de avaliação.
    if not (v_changed <@ array['status', 'rating', 'rating_comment', 'rating_by']) then
      raise exception 'CLIENT_COL_FORBIDDEN' using errcode = 'P0001';
    end if;

    -- mexeu em `status` → SÓ status, de ativo p/ 'cancelado'.
    if 'status' = any (v_changed) then
      if not coalesce(
             cardinality(v_changed) = 1
         and old.status in ('pendente', 'confirmado')
         and new.status = 'cancelado'
       , false) then
        raise exception 'CLIENT_STATUS_FORBIDDEN' using errcode = 'P0001';
      end if;
      return new;
    end if;

    -- delta ⊆ {rating, rating_comment, rating_by} → avaliar o PRÓPRIO corte,
    -- one-shot (D-H9): TODAS as condições, `rating` de fato no delta.
    if not coalesce(
           'rating' = any (v_changed)
       and old.status = 'concluido'
       and old.rating is null
       and new.rating between 1 and 5
       and new.rating_by = 'cliente'
     , false) then
      raise exception 'CLIENT_RATING_FORBIDDEN' using errcode = 'P0001';
    end if;
    return new;
  end if;

  -- ── STAFF operacional ──────────────────────────────────────────────────────
  -- barbeiro na PRÓPRIA agenda (OLD.barber_id = auth.uid()) OU admin/vendas
  -- (escopo global por policy). Conjunto comum operacional (D-H11).
  if not (v_changed <@ array[
    'status', 'iniciado_em', 'day', 'day_label', 'time', 'duration',
    'services', 'discount_price', 'notes',
    'client_rating', 'client_rating_comment', 'barber_reply', 'reminder_sent_at'
  ]) then
    raise exception 'STAFF_COL_FORBIDDEN' using errcode = 'P0001';
  end if;

  return new;
end;
$$;

revoke execute on function public._appointments_guard_update()
  from public, anon, authenticated, service_role;
