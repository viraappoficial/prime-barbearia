-- ST-H.5 — higiene de grants residuais (H-F / D-H7).
--
-- Resíduo do `GRANT ALL` do baseline. Nenhum é usado pelo legado nem pela
-- Prime Next; nenhum deveria estar ao alcance de `anon` / `authenticated`:
--   INSERT/UPDATE/DELETE de `anon` em appointments → a RLS já nega (nenhuma
--     policy de escrita p/ anon), mas o grant é superfície. No LAB o
--     20260829000600 já revogou; em PRODUÇÃO não — aqui é idempotente.
--   TRUNCATE   → apagaria a tabela inteira (a RLS não protege TRUNCATE);
--   TRIGGER    → criar/dropar trigger na tabela;
--   REFERENCES → criar FK apontando pra tabela.
--
-- SELECT de `anon` é MANTIDO (a RLS já zera as linhas; a leitura pública real
-- é pelas RPCs agregadas). `crm_clients` só perde truncate/trigger/references —
-- o aperto de INSERT/UPDATE/DELETE de `anon` em `crm_clients` (hoje `GRANT ALL`,
-- mas RLS `barber_id = auth.uid()` já nega p/ anon) fica p/ a higiene do CRM
-- (ST-3), junto com a curadoria de `clients_readable_by_barbers`.
--
-- Rollback:
--   grant insert, update, delete on public.appointments to anon;
--   grant truncate, trigger, references on
--     public.appointments, public.crm_clients, public.notifications
--     to anon, authenticated;
-- Impacto no legado: nenhum comportamental — nada exerce esses privilégios.

revoke insert, update, delete on public.appointments from anon;

revoke truncate, trigger, references on
  public.appointments,
  public.crm_clients,
  public.notifications
  from anon, authenticated;
