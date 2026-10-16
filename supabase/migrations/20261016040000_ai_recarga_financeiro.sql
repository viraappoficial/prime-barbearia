-- Recarga da conta de IA (Anthropic) vira custo no Financeiro: despesa paga em "Mensalidade sistema — Inteligência Artificial".
-- A recarga também vira um novo ponto de saldo (ai_balance), pra tela Gestão > IA continuar descontando o consumo daí.
insert into public.chart_of_accounts (slug, name, is_taxa_maquininha)
values ('inteligencia_artificial', 'Mensalidade sistema — Inteligência Artificial', false)
on conflict (slug) do nothing;

alter table public.ai_balance
  add column if not exists topup_usd numeric(12,4),
  add column if not exists cost_brl numeric(12,2),
  add column if not exists expense_id bigint references public.expenses(id) on delete set null;

create or replace function public.ai_register_topup(p_usd numeric, p_brl numeric, p_date date, p_balance_after numeric, p_bank_account_id bigint default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_exp bigint;
begin
  if not exists (select 1 from barbers b where b.id = auth.uid() and b.role = 'admin') then
    raise exception 'NOT_ADMIN';
  end if;
  if p_usd is null or p_usd <= 0 or p_brl is null or p_brl <= 0 then
    raise exception 'VALOR_INVALIDO';
  end if;
  insert into expenses (name, category, value, date, due_date, status, paid_at, paid_method, bank_account_id, payment_type)
  values ('Inteligência artificial — recarga US$ ' || to_char(p_usd, 'FM999990.00'), 'inteligencia_artificial', p_brl, coalesce(p_date, current_date), coalesce(p_date, current_date),
          'pago', coalesce(p_date, current_date), 'banco', p_bank_account_id, 'normal')
  returning id into v_exp;
  insert into ai_balance (balance_usd, topup_usd, cost_brl, expense_id, note)
  values (greatest(0, coalesce(p_balance_after, p_usd)), p_usd, p_brl, v_exp, 'recarga');
  return v_exp;
end;
$$;
revoke all on function public.ai_register_topup(numeric, numeric, date, numeric, bigint) from public, anon;
grant execute on function public.ai_register_topup(numeric, numeric, date, numeric, bigint) to authenticated;
