-- ST-H.3 — proteção de colunas de `public.appointments` no UPDATE direto.
--
-- ⚠️ NÃO é "baixo risco" (D-H8). Troca o `GRANT UPDATE` tabela-inteira por 16
-- colunas E põe um trigger `BEFORE UPDATE` no caminho de TODO update de
-- `appointments` — o legado (`#barberApp`, `#clientApp`) incluído. Um erro no
-- allow-list quebra um fluxo legado. Rollout com gates (proposta §9).
--
-- ── Por que grant de coluna não basta ──
-- `GRANT UPDATE (cols)` é por ROLE (`authenticated` = cliente + staff) e é
-- checado ANTES da RLS. Não expressa "cliente pode `status`, mas só p/
-- 'cancelado'" nem "cliente não pode `services`, mas o barbeiro pode". A RLS
-- (`WITH CHECK`) só enxerga a linha NEW, não compara OLD × NEW. Só um trigger
-- `BEFORE UPDATE FOR EACH ROW` vê o delta. Daí as duas camadas:
--
-- ── Camada 1 — grant de coluna (defesa externa grossa) ──
-- `authenticated` passa a ter UPDATE só nas 16 colunas que ALGUM fluxo legado
-- de fato atualiza (união de cliente + staff). As 8 estruturais
-- (id, client_id, barber_id, client_name, client_email, is_encaixe,
--  coupon_code, created_at) saem — PATCH nelas → 403 no grant, antes do trigger.
--   NOTA (conciliação com a proposta): a proposta §5.3 lista 15 e a §9 fala em
--   "19"; ambas estão frouxas. A união REAL dos allow-lists por papel (§5.4) é
--   16 e é o que o Gate 0 (79 OK) exercitou. `notes` ENTRA (o barbeiro grava
--   observação do atendimento — §5.4 linha 21); as 3 de avaliação do cliente
--   (rating/rating_comment/rating_by) entram porque o cliente é `authenticated`.
--
-- ── Camada 2 — trigger `_appointments_guard_update()` (fino, por papel) ──
-- `SECURITY INVOKER` (crítico: com DEFINER `current_user` seria o owner e o
-- guard não saberia quem chamou — MEDIDO no Gate 0, §5.3-bis), `search_path=''`.
-- ALLOW-LIST por papel efetivo, default-deny: qualquer coluna do delta fora do
-- conjunto do papel → `raise`. Coluna nova na tabela = bloqueada até
-- classificar (o delta é dinâmico via `jsonb_each`).
--   • bypass p/ current_user in (postgres, supabase_admin, service_role) —
--     RPCs SECURITY DEFINER (owner) e backend fazem a própria validação.
--   • cliente / não-staff (barber_role() is null; a RLS clients_update_own já
--     garante que é o dono da linha). Vocabulário INTEIRO = {status, rating,
--     rating_comment, rating_by}:
--       – delta com QUALQUER coluna fora do vocabulário → CLIENT_COL_FORBIDDEN
--         (estrutural, operacional, permitida-p/-staff, ou coluna futura).
--       – mexeu em `status` → delta = {status} exatamente, OLD ∈ {pendente,
--         confirmado}, NEW = 'cancelado'; senão CLIENT_STATUS_FORBIDDEN.
--       – delta ⊆ {rating,rating_comment,rating_by} → `rating` de fato no delta,
--         OLD.status='concluido', OLD.rating null, NEW.rating ∈ [1,5],
--         NEW.rating_by='cliente' — TODAS (D-H9, one-shot); senão
--         CLIENT_RATING_FORBIDDEN.
--       – delta vazio (PATCH que não muda nada) → passa, no-op.
--   • staff (barbeiro / vendas / admin — D-H11 compartilham o conjunto): delta
--     ⊆ {status, iniciado_em, day, day_label, time, duration, services,
--        discount_price, notes, client_rating, client_rating_comment,
--        barber_reply, reminder_sent_at}. Senão → STAFF_COL_FORBIDDEN.
--     (rating/rating_comment/rating_by são do CLIENTE → staff é barrado nelas
--      pelo trigger, mesmo estando no grant.)
--     ST-2 move services/discount_price/client_rating* p/ RPC de checkout e o
--     guard passa a rejeitá-las p/ staff também.
--
-- Ordem no UPDATE: grant de coluna → RLS USING → ESTE trigger → RLS WITH CHECK
-- → escrita.
--
-- Rollback:
--   drop trigger if exists appointments_guard_update on public.appointments;
--   drop function if exists public._appointments_guard_update();
--   revoke update (status, iniciado_em, day, day_label, time, duration,
--     services, discount_price, notes, rating, rating_comment, rating_by,
--     client_rating, client_rating_comment, barber_reply, reminder_sent_at)
--     on public.appointments from authenticated;
--   grant update on public.appointments to authenticated;
--   -- (baseline de produção também tinha UPDATE p/ anon; no lab o
--   --  20260829000600 já revogou. Restaurar só se for reverter em produção:
--   --  grant update on public.appointments to anon; )
-- Impacto no legado: as 16 colunas que o legado atualiza continuam graváveis
-- pelos papéis que já as gravavam. O que muda: o cliente deixa de conseguir
-- editar preço/serviço/data/barbeiro/status(≠cancelar)/avaliação-repetida da
-- própria linha (§5.2-bis — hoje é 200).

-- ── Camada 1 ──────────────────────────────────────────────────────────────────
revoke update on public.appointments from anon, authenticated;

grant update (
  status, iniciado_em,
  day, day_label, time, duration,
  services, discount_price, notes,
  rating, rating_comment, rating_by,
  client_rating, client_rating_comment, barber_reply, reminder_sent_at
) on public.appointments to authenticated;

-- ── Camada 2 ──────────────────────────────────────────────────────────────────
create or replace function public._appointments_guard_update()
returns trigger
language plpgsql
security invoker            -- current_user = o role do request real (Gate 0 §5.3-bis)
set search_path = ''
as $$
declare
  v_role    text;
  v_changed text[];
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

  -- ── CLIENTE / não-staff (RLS clients_update_own já garante que é o dono) ──
  if v_role is null then

    -- vocabulário INTEIRO do cliente no UPDATE direto: {status} + as 3 de
    -- avaliação. Qualquer coluna do delta fora disso (estrutural, operacional,
    -- permitida-p/-staff, ou coluna futura) → CLIENT_COL_FORBIDDEN.
    if not (v_changed <@ array['status', 'rating', 'rating_comment', 'rating_by']) then
      raise exception 'CLIENT_COL_FORBIDDEN' using errcode = 'P0001';
    end if;

    -- mexeu em `status` → tem que ser SÓ status, de ativo p/ 'cancelado'.
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

  -- ── STAFF (barbeiro / vendas / admin) — conjunto comum operacional (D-H11) ──
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

create or replace trigger appointments_guard_update
  before update on public.appointments
  for each row
  execute function public._appointments_guard_update();
