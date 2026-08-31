-- ST-2.1 — sequence server-side para `nota_id` (fim do contador localStorage).
--
-- ACHADO B1 (proposta `prime-next:docs/investigacoes/10-staff-st2-checkout.md`
-- §4.8): `nota_id` hoje é um contador `localStorage` do browser (`primeNextId`)
-- — colisão garantida entre dispositivos; nenhum FK / unique em
-- `sales`/`sale_payments`/`fiado_charges`. Esta migration cria a fonte
-- server-side que `staff_checkout` (ST-2.5) usa.
--
-- GATE DE PRODUÇÃO (D-ST2-18): `setval(max+1)` NÃO faz os dois produtores
-- (contador do legado + esta sequence) conviverem em segurança. NO LAB só a
-- ST-2 escreve venda → a sequence é a única fonte. EM PRODUÇÃO a ST-2 de
-- checkout só entra depois que o legado (a) cortar pra RPC, (b) passar a chamar
-- um alocador server-side comum, ou (c) cutover de venda. **NÃO afirmar
-- "convivência segura".**
--
-- Rollback: drop sequence public.sales_nota_seq;
-- Impacto no legado: nenhum — o `#barberApp` segue com `primeNextId()`
-- (contador `localStorage`); esta sequence não é chamada por nada do legado.

create sequence if not exists public.sales_nota_seq as bigint;

-- ancora acima do maior nota_id já gravado (linhas antigas ficam como estão —
-- D-ST2-11). Só AVANÇA, nunca regride → idempotente e seguro em re-run mesmo
-- depois que `staff_checkout` já tiver consumido `nextval`.
do $$
declare
  v_max      bigint := greatest(
    (select coalesce(max(nota_id), 0) from public.sales),
    (select coalesce(max(nota_id), 0) from public.sale_payments),
    (select coalesce(max(nota_id), 0) from public.fiado_charges));
  v_called   boolean := (select is_called from public.sales_nota_seq);
  v_last     bigint  := (select last_value from public.sales_nota_seq);
begin
  if v_called is not true or v_last < v_max + 1 then
    perform setval('public.sales_nota_seq', v_max + 1, false);
    raise notice 'ST-2.1: sales_nota_seq ancorada em % (próximo nextval)', v_max + 1;
  else
    raise notice 'ST-2.1: sales_nota_seq já à frente (last_value=%, max histórico=%) — no-op', v_last, v_max;
  end if;
end $$;

-- só o owner (postgres) chama `nextval`, de dentro de `staff_checkout`.
revoke all on sequence public.sales_nota_seq from public, anon, authenticated, service_role;
