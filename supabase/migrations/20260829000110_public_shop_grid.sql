-- Leitura pública da grade da agenda (opção B do achado em 20260829000000).
--
-- `shop_settings` já existe e sua policy de SELECT (`shop_settings_select_all`)
-- é staff-only. O frontend/servidor da Prime Next precisa de slot_min +
-- open_hours + max_advance_days + timezone para montar a grade — mas NÃO deve
-- ver `comissao_fiado_na_hora` (config financeira) nem virar a policy de
-- SELECT pública.
--
-- Esta RPC devolve SÓ os 4 campos da grade. SECURITY DEFINER (lê como owner),
-- search_path fixo, zero PII, zero campo financeiro.
--
-- Rollback: drop function public.public_shop_grid();
-- Impacto: nenhum — só adiciona uma leitura pública restrita.

create or replace function public.public_shop_grid()
returns table(slot_min integer, open_hours jsonb, max_advance_days integer, timezone text)
language sql
stable
security definer
set search_path = ''
as $$
  select s.slot_min, s.open_hours, s.max_advance_days, s.timezone
  from public.shop_settings s
  where s.id = 1
$$;

revoke execute on function public.public_shop_grid()
  from public, anon, authenticated, service_role;
grant execute on function public.public_shop_grid() to anon, authenticated;
