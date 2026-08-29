-- Hardening: validate_coupon é SECURITY DEFINER SEM `SET search_path`.
--
-- Uma função SECURITY DEFINER sem search_path fixo é vulnerável a hijack de
-- search_path (o chamador pode plantar uma tabela `coupons` num schema à frente
-- de `public`). Corrigido aqui: search_path fixo + objeto qualificado.
--
-- Rollback:
--   alter function public.validate_coupon(text) reset search_path;
--   -- e recriar o corpo sem o schema-qualify, se quiser voltar exatamente.
-- Impacto: nenhum comportamental — a função continua devolvendo o mesmo cupom.

create or replace function public.validate_coupon(p_code text)
returns table(code text, type text, value numeric, services text[])
language sql
stable
security definer
set search_path = ''
as $$
  select c.code, c.type, c.value, c.services
  from public.coupons c
  where c.code = upper(trim(p_code)) and c.active = true
$$;

-- grants como já eram (anon+authenticated), sem o service_role amplo herdado.
-- `validate_coupon` já existia com GRANT a anon/authenticated/service_role
-- (baseline). O `create or replace` re-emite as default privileges; a única
-- mudança de comportamento é o `search_path` fixo. Mantém o mesmo conjunto de
-- grants (nada de regressão), só tira o PUBLIC implícito.
revoke execute on function public.validate_coupon(text) from public;
grant execute on function public.validate_coupon(text) to anon, authenticated, service_role;
