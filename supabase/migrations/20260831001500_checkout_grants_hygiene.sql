-- ST-2.6 — higiene de grants residuais nas tabelas de venda (B11).
--
-- Mesmo achado H-F / D-H7 da ST-H.5: o `GRANT ALL` do baseline deixa `anon` e
-- `authenticated` com `TRUNCATE` (a RLS não protege), `TRIGGER` e `REFERENCES`
-- em TODA tabela de checkout. Nenhum é usado pelo legado nem pela Prime Next.
--
-- **Mantidos** INSERT / UPDATE / DELETE / SELECT até o cutover de venda — a RLS
-- já filtra (`*_insert_own` / `*_vendas` / `*_admin`) e o `#barberApp` legado
-- ainda escreve direto. O cutover (fatia futura) revoga INSERT/UPDATE/DELETE e
-- dropa as policies de escrita, deixando só as RPCs.
--
-- Rollback:
--   grant truncate, trigger, references on
--     public.sales, public.sale_payments, public.cart_items, public.coupons,
--     public.products, public.services, public.taxas_maquininha,
--     public.cash_closures, public.cash_sangrias, public.cash_supplies,
--     public.bank_accounts, public.fiado_charges, public.fiado_invoices
--     to anon, authenticated;
-- Impacto no legado: nenhum comportamental — nada exerce TRUNCATE/TRIGGER/REFERENCES.

revoke truncate, trigger, references on
  public.sales,
  public.sale_payments,
  public.cart_items,
  public.coupons,
  public.products,
  public.services,
  public.taxas_maquininha,
  public.cash_closures,
  public.cash_sangrias,
  public.cash_supplies,
  public.bank_accounts,
  public.fiado_charges,
  public.fiado_invoices
  from anon, authenticated;

-- `staff_checkout_log` já nasce sem GRANT ALL (ST-2.5: revoke all + grant select).
