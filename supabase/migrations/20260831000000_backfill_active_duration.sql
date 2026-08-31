-- ST-1b.0 — backfill dirigido de `appointments.duration` NULL em agenda ATIVA.
--
-- O cutover (20260829010000) NÃO foi aplicado: `appointments.duration` ainda é
-- nullable e o `#clientApp` legado nunca a gravava. Há linhas ATIVAS
-- (`pendente`/`confirmado`) com `duration IS NULL`. A checagem de sobreposição de
-- intervalo da ST-1b (`_staff_insert_appointment`) NÃO pode:
--   - fazer aritmética com NULL (`v_start < NULL + …` → NULL → a linha "não
--     conflita" → FURO);
--   - usar fallback silencioso `coalesce(duration, slot_min)` — encolhe um
--     serviço de 90 min para 45 e libera um slot na verdade ocupado.
--
-- Esta migration é OBRIGATÓRIA e SEMPRE presente no conjunto (não "só se achar
-- linhas"). Roda o preflight em runtime → mesmo caminho em qualquer ambiente:
--   - 0 ativos NULL           → no-op REGISTRADO (`raise notice`);
--   - todos resolvem pelo catálogo (por nome) → backfill pela SOMA REAL;
--   - algum ativo NÃO resolve  → `raise exception` (lista os ids) → ABORTA.
--
-- Sem fallback `slot_min` para agenda ativa (mesma regra do §0 do cutover).
-- NÃO põe `NOT NULL` na coluna — isso é do cutover. Só backfilla os ativos; o
-- histórico inativo com `duration NULL` é ignorado (não entra na sobreposição,
-- cujo filtro é `status in ('pendente','confirmado')`).
--
-- Rollback: o backfill é irreversível por natureza. O `raise notice` final lista
-- quantas linhas foram preenchidas; o valor anterior era sempre NULL. Reverter =
-- restaurar as linhas do dump / `update ... set duration = null where id = any(<ids>)`.
-- Impacto no legado: um agendamento ativo passa a ter `duration` = soma real dos
-- serviços (antes NULL). Benigno e desejado — necessário para a agenda de staff.

do $$
declare
  v_null    int;
  v_bad     int;
  v_bad_ids bigint[];
begin
  select count(*) into v_null
  from public.appointments
  where status in ('pendente', 'confirmado') and duration is null;

  if v_null = 0 then
    raise notice 'ST-1b.0: no-op — 0 agendamentos ativos com duration NULL.';
    return;
  end if;

  -- dos ativos NULL, quais NÃO resolvem 100% pelo catálogo atual (por nome)?
  select count(*), array_agg(a.id order by a.id)
    into v_bad, v_bad_ids
  from public.appointments a
  where a.status in ('pendente', 'confirmado')
    and a.duration is null
    and coalesce(cardinality(a.services), 0) <> (
      select count(*) from public.services s where s.name = any(a.services)
    );

  if v_bad > 0 then
    raise exception
      'ST-1b.0 abortada: % agendamento(s) ATIVO(s) com duration NULL e servicos nao resolviveis pelo catalogo atual (ids: %). Corrigir a mao (setar duration ou ajustar services) antes de re-rodar. SEM fallback.',
      v_bad, v_bad_ids
      using errcode = 'P0001';
  end if;

  update public.appointments a
  set duration = (
    select sum(s.duration_min) from public.services s where s.name = any(a.services)
  )
  where a.status in ('pendente', 'confirmado') and a.duration is null;

  raise notice 'ST-1b.0: % agendamento(s) ativo(s) tiveram duration preenchida pelo catalogo.', v_null;
end $$;
