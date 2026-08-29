-- Higiene: remove de `anon` os privilégios residuais em `appointments` e
-- `appointment_waitlist` que sobraram do `GRANT ALL` do baseline.
--
-- O lote normal (20260829000600) revogou `INSERT/UPDATE/DELETE` de `anon`.
-- Ainda restam `TRUNCATE`, `TRIGGER` e `REFERENCES` — nenhum é usado pelo
-- legado nem pela Prime Next, e nenhum deveria estar ao alcance de `anon`:
--   TRUNCATE   → apagaria a tabela inteira (RLS não protege TRUNCATE);
--   TRIGGER    → criar/dropar trigger na tabela;
--   REFERENCES → criar FK apontando pra tabela.
--
-- `SELECT` de `anon` é MANTIDO: a RLS (`clients_select_own` etc.) já zera as
-- linhas pra `anon`, e a leitura pública real da agenda é pelas RPCs agregadas
-- (`public_day_availability`, `public_shop_grid`). Se ficar comprovado que
-- nenhum caminho anon lê essas tabelas, um lote futuro pode revogar o SELECT
-- também.
--
-- ⚠️ NÃO APLICAR ainda — nem no lab, nem em produção. Registrada para um
-- próximo lote de higiene, junto com a matriz de regressão.
--
-- Rollback:
--   grant truncate, trigger, references on public.appointments        to anon;
--   grant truncate, trigger, references on public.appointment_waitlist to anon;
-- Impacto: nenhum comportamental — nada no legado ou na Prime Next exerce
-- esses privilégios como `anon`.

revoke truncate, trigger, references on public.appointments        from anon;
revoke truncate, trigger, references on public.appointment_waitlist from anon;
