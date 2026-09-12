-- ST-4.1 — núcleo de Caixa (suprimento/sangria/saldo), admin-only.
--
-- Fórmulas verificadas 1:1 contra o legado (`baCashRegisterBalance`,
-- `baCashVaultBalance`, `baStartSuprimento`, `baStartSangria`,
-- index.html ~L6573-6790). Não existe ledger — o saldo é sempre
-- computado em runtime.
--
-- Saldo do CAIXA (dinheiro físico), desde o `period_to` do último
-- `cash_closures` (ou desde sempre, se nunca fechou):
--   recebido (sale_payments.dinheiro) + suprido (cash_supplies, qualquer
--   origem) − sangrias saídas do caixa (cash_sangrias.origem='caixa').
--
-- Saldo do COFRE (empresa), não janelado por fechamento — é acumulado
-- desde sempre:
--   entradas (sangrias caixa→cofre) − saídas (sangrias saindo do cofre +
--   supplies tirados do cofre pro caixa + despesas pagas em dinheiro, que
--   saem do cofre, nunca do caixa).
--
-- Autorização: só `role='admin'` (helper `_caixa_ctx()`, mesmo padrão de
-- `_crm_ctx()` mas específico deste domínio — barbeiro/vendas não têm
-- acesso ao Caixa no legado nem aqui).
--
-- Design: o cálculo de saldo vive em `_caixa_saldo_calc()` (privada), usada
-- por `staff_caixa_saldo()` E pelas RPCs de escrita — suprimento/sangria
-- devolvem o saldo JÁ ATUALIZADO na resposta, então o client nunca precisa
-- recalcular a fórmula (evita duplicar/divergir a lógica financeira no
-- front, mesmo espírito de "servidor é dono da verdade" do resto do CRM).
--
-- Fora desta fatia (ver docs/investigacoes/16-staff-st4-caixa.md):
-- fechamento de período (ST-4.2), comissões/DRE (ST-4.3/.4).
--
-- Rollback:
--   drop function public.staff_caixa_saldo();
--   drop function public.staff_caixa_suprimento(numeric, text, bigint, text);
--   drop function public.staff_caixa_sangria(numeric, text, text, bigint, text);
--   drop function public.staff_caixa_historico();
--   drop function public.staff_caixa_contas_bancarias();
--   drop function public._caixa_saldo_calc();
--   drop function public._caixa_ctx();
-- Impacto no legado: nenhum (só leitura + insert nas mesmas tabelas que o
-- legado já usa via PostgREST direto).

create or replace function public._caixa_ctx()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_role text;
begin
  if v_uid is null then
    raise exception 'NOT_AUTH' using errcode = 'P0001';
  end if;
  select role into v_role from public.barbers where id = v_uid;
  if v_role is distinct from 'admin' then
    raise exception 'NOT_STAFF' using errcode = 'P0001';
  end if;
  return v_uid;
end;
$$;

-- Privada (sem grant) — só chamada de dentro das RPCs acima, que já
-- passaram por `_caixa_ctx()`.
create or replace function public._caixa_saldo_calc()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_since date;
  v_caixa numeric;
  v_cofre numeric;
begin
  select period_to into v_since from public.cash_closures order by period_to desc limit 1;
  v_since := coalesce(v_since, '1900-01-01'::date);

  select
      coalesce((select sum(p.value) from public.sale_payments p
                where p.method = 'dinheiro' and p.created_at::date > v_since), 0)
    + coalesce((select sum(s.value) from public.cash_supplies s
                where s.created_at::date > v_since), 0)
    - coalesce((select sum(g.value) from public.cash_sangrias g
                where g.origem = 'caixa' and g.created_at::date > v_since), 0)
  into v_caixa;

  select
      coalesce((select sum(g.value) from public.cash_sangrias g
                where g.destino = 'cofre' and g.origem = 'caixa'), 0)
    - coalesce((select sum(g.value) from public.cash_sangrias g
                where g.origem = 'cofre'), 0)
    - coalesce((select sum(s.value) from public.cash_supplies s
                where s.origem = 'cofre'), 0)
    - coalesce((select sum(e.value) from public.expenses e
                where e.status = 'pago' and e.paid_method = 'dinheiro'), 0)
  into v_cofre;

  return jsonb_build_object('caixa', v_caixa, 'cofre', v_cofre, 'desde', v_since);
end;
$$;

create or replace function public.staff_caixa_saldo()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public._caixa_ctx();
  return public._caixa_saldo_calc();
end;
$$;

create or replace function public.staff_caixa_suprimento(
  p_value           numeric,
  p_origem          text,
  p_bank_account_id bigint default null,
  p_note            text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid  uuid;
  v_note text;
  v_id   bigint;
begin
  v_uid := public._caixa_ctx();

  if p_value is null or p_value <= 0 then
    raise exception 'BAD_INPUT' using errcode = 'P0001';
  end if;
  if p_origem not in ('cofre', 'banco', 'outro') then
    raise exception 'BAD_INPUT' using errcode = 'P0001';
  end if;
  if p_origem = 'banco' then
    if p_bank_account_id is null
       or not exists (select 1 from public.bank_accounts where id = p_bank_account_id) then
      raise exception 'BAD_INPUT' using errcode = 'P0001';
    end if;
  end if;

  v_note := nullif(trim(both from coalesce(p_note, '')), '');
  if v_note is not null and length(v_note) > 300 then
    v_note := left(v_note, 300);
  end if;

  insert into public.cash_supplies (value, origem, bank_account_id, admin_id, barber_id, note)
  values (
    p_value, p_origem,
    case when p_origem = 'banco' then p_bank_account_id else null end,
    v_uid, v_uid, v_note
  )
  returning id into v_id;

  return public._caixa_saldo_calc() || jsonb_build_object('id', v_id);
end;
$$;

create or replace function public.staff_caixa_sangria(
  p_value           numeric,
  p_origem          text,
  p_destino         text,
  p_bank_account_id bigint default null,
  p_note            text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid  uuid;
  v_note text;
  v_id   bigint;
begin
  v_uid := public._caixa_ctx();

  if p_value is null or p_value <= 0 then
    raise exception 'BAD_INPUT' using errcode = 'P0001';
  end if;
  if p_origem not in ('caixa', 'cofre') then
    raise exception 'BAD_INPUT' using errcode = 'P0001';
  end if;
  if p_destino not in ('cofre', 'banco') then
    raise exception 'BAD_INPUT' using errcode = 'P0001';
  end if;
  -- sangria saindo do cofre só pode ir pro banco (cofre→cofre não faz
  -- sentido; cofre→caixa já é suprimento) — mesma regra do legado
  -- (`baSangriaOrigemChanged`).
  if p_origem = 'cofre' and p_destino <> 'banco' then
    raise exception 'BAD_INPUT' using errcode = 'P0001';
  end if;
  if p_destino = 'banco' then
    if p_bank_account_id is null
       or not exists (select 1 from public.bank_accounts where id = p_bank_account_id) then
      raise exception 'BAD_INPUT' using errcode = 'P0001';
    end if;
  end if;

  v_note := nullif(trim(both from coalesce(p_note, '')), '');
  if v_note is not null and length(v_note) > 300 then
    v_note := left(v_note, 300);
  end if;

  insert into public.cash_sangrias (value, origem, destino, bank_account_id, admin_id, barber_id, note)
  values (
    p_value, p_origem, p_destino,
    case when p_destino = 'banco' then p_bank_account_id else null end,
    v_uid, v_uid, v_note
  )
  returning id into v_id;

  return public._caixa_saldo_calc() || jsonb_build_object('id', v_id);
end;
$$;

create or replace function public.staff_caixa_historico()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_supplies jsonb;
  v_sangrias jsonb;
begin
  perform public._caixa_ctx();

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', s.id, 'value', s.value, 'origem', s.origem,
      'banco_nome', ba.name, 'note', s.note, 'created_at', s.created_at
    ) order by s.created_at desc), '[]'::jsonb)
  into v_supplies
  from (select * from public.cash_supplies order by created_at desc limit 20) s
  left join public.bank_accounts ba on ba.id = s.bank_account_id;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', g.id, 'value', g.value, 'origem', g.origem, 'destino', g.destino,
      'banco_nome', ba.name, 'note', g.note, 'created_at', g.created_at
    ) order by g.created_at desc), '[]'::jsonb)
  into v_sangrias
  from (select * from public.cash_sangrias order by created_at desc limit 20) g
  left join public.bank_accounts ba on ba.id = g.bank_account_id;

  return jsonb_build_object('suprimentos', v_supplies, 'sangrias', v_sangrias);
end;
$$;

create or replace function public.staff_caixa_contas_bancarias()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public._caixa_ctx();
  return coalesce(
    (select jsonb_agg(jsonb_build_object('id', id, 'nome', name) order by name)
     from public.bank_accounts),
    '[]'::jsonb
  );
end;
$$;

revoke execute on function public._caixa_ctx() from public, anon, authenticated, service_role;
revoke execute on function public._caixa_saldo_calc() from public, anon, authenticated, service_role;
revoke execute on function public.staff_caixa_saldo() from public, anon, authenticated, service_role;
grant execute on function public.staff_caixa_saldo() to authenticated;
revoke execute on function public.staff_caixa_suprimento(numeric, text, bigint, text) from public, anon, authenticated, service_role;
grant execute on function public.staff_caixa_suprimento(numeric, text, bigint, text) to authenticated;
revoke execute on function public.staff_caixa_sangria(numeric, text, text, bigint, text) from public, anon, authenticated, service_role;
grant execute on function public.staff_caixa_sangria(numeric, text, text, bigint, text) to authenticated;
revoke execute on function public.staff_caixa_historico() from public, anon, authenticated, service_role;
grant execute on function public.staff_caixa_historico() to authenticated;
revoke execute on function public.staff_caixa_contas_bancarias() from public, anon, authenticated, service_role;
grant execute on function public.staff_caixa_contas_bancarias() to authenticated;
