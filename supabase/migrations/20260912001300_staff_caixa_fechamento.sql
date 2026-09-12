-- ST-4.2 — fechamento de período do Caixa, admin-only.
--
-- Fórmula verificada 1:1 contra o legado (`baCalcularFechamento`/
-- `baFecharCaixa`, index.html ~L6725-6772): pro período [from, to]
-- (inclusive nas duas pontas):
--   recebido (sale_payments.dinheiro no período) + suprido (cash_supplies,
--   qualquer origem, no período) − sangrias saídas do caixa
--   (cash_sangrias.origem='caixa' no período) = esperado.
--   diferença = contado (informado pelo admin) − esperado.
--
-- Diferente do legado (que calcula `esperado` no BROWSER e manda pro
-- INSERT): aqui o servidor SEMPRE recalcula `esperado` a partir do período
-- — o client nunca manda `expected_value`, só `p_from`/`p_to`/`p_contado`.
-- Isso fecha um vetor de adulteração que o legado tinha (cliente podia
-- mandar `expected_value` arbitrário direto no `insert`).
--
-- Sem verificação de sobreposição de período (paridade — o legado também
-- não valida). Registrado como achado, não corrigido nesta fatia (mesmo
-- padrão do projeto: não inventar hardening além do que foi decidido).
--
-- Depende de ST-4.1 (`_caixa_ctx()`).
--
-- Rollback:
--   drop function public.staff_caixa_calcular_fechamento(date, date);
--   drop function public.staff_caixa_fechar(date, date, numeric);
--   drop function public.staff_caixa_fechamentos();
--   drop function public._caixa_fechamento_calc(date, date);
-- Impacto no legado: nenhum (mesma tabela `cash_closures`, mesmo cálculo).

create or replace function public._caixa_fechamento_calc(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_recebido numeric;
  v_suprido  numeric;
  v_sangrias numeric;
begin
  select coalesce(sum(p.value), 0) into v_recebido
  from public.sale_payments p
  where p.method = 'dinheiro' and p.created_at::date between p_from and p_to;

  select coalesce(sum(s.value), 0) into v_suprido
  from public.cash_supplies s
  where s.created_at::date between p_from and p_to;

  select coalesce(sum(g.value), 0) into v_sangrias
  from public.cash_sangrias g
  where g.origem = 'caixa' and g.created_at::date between p_from and p_to;

  return jsonb_build_object(
    'recebido', v_recebido, 'suprido', v_suprido, 'sangrias', v_sangrias,
    'esperado', v_recebido + v_suprido - v_sangrias
  );
end;
$$;

create or replace function public.staff_caixa_calcular_fechamento(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public._caixa_ctx();
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'BAD_INPUT' using errcode = 'P0001';
  end if;
  return public._caixa_fechamento_calc(p_from, p_to);
end;
$$;

create or replace function public.staff_caixa_fechar(p_from date, p_to date, p_contado numeric)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid      uuid;
  v_calc     jsonb;
  v_esperado numeric;
  v_id       bigint;
begin
  v_uid := public._caixa_ctx();

  if p_from is null or p_to is null or p_from > p_to or p_contado is null then
    raise exception 'BAD_INPUT' using errcode = 'P0001';
  end if;

  -- esperado é SEMPRE recalculado aqui, nunca recebido do client (fecha o
  -- vetor de adulteração que o legado tinha).
  v_calc := public._caixa_fechamento_calc(p_from, p_to);
  v_esperado := (v_calc ->> 'esperado')::numeric;

  insert into public.cash_closures (period_from, period_to, expected_value, counted_value, difference, admin_id)
  values (p_from, p_to, v_esperado, p_contado, p_contado - v_esperado, v_uid)
  returning id into v_id;

  return v_calc || jsonb_build_object('id', v_id, 'contado', p_contado, 'diferenca', p_contado - v_esperado);
end;
$$;

create or replace function public.staff_caixa_fechamentos()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public._caixa_ctx();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
        'id', c.id, 'period_from', c.period_from, 'period_to', c.period_to,
        'expected_value', c.expected_value, 'counted_value', c.counted_value,
        'difference', c.difference, 'created_at', c.created_at
      ) order by c.created_at desc)
    from (select * from public.cash_closures order by created_at desc limit 20) c
  ), '[]'::jsonb);
end;
$$;

revoke execute on function public._caixa_fechamento_calc(date, date) from public, anon, authenticated, service_role;
revoke execute on function public.staff_caixa_calcular_fechamento(date, date) from public, anon, authenticated, service_role;
grant execute on function public.staff_caixa_calcular_fechamento(date, date) to authenticated;
revoke execute on function public.staff_caixa_fechar(date, date, numeric) from public, anon, authenticated, service_role;
grant execute on function public.staff_caixa_fechar(date, date, numeric) to authenticated;
revoke execute on function public.staff_caixa_fechamentos() from public, anon, authenticated, service_role;
grant execute on function public.staff_caixa_fechamentos() to authenticated;
