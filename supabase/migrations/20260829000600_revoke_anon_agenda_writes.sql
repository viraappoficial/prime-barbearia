-- P2 (parte anon): remove os grants amplos de escrita de `anon` na agenda.
--
-- Baseline: `GRANT ALL ON appointments TO anon` e idem appointment_waitlist.
-- A RLS já nega (não há policy de escrita pra anon), mas o grant é superfície
-- desnecessária. O legado NUNCA escreve agenda como anon (só cliente logado),
-- então revogar de `anon` é seguro em produção — é só higiene.
--
-- O bloqueio da escrita direta do CLIENTE (`authenticated`) fica na migration
-- de CUTOVER (20260829010000) — e é feito dropando as policies
-- `clients_insert_own`/`clients_update_own`, não revogando o grant (o grant é
-- compartilhado com o staff, que continua escrevendo direto no app legado).
--
-- Rollback:
--   grant insert, update, delete on public.appointments to anon;
--   grant insert, update, delete on public.appointment_waitlist to anon;
-- Impacto: nenhum — anon já não conseguia escrever (RLS). SELECT de anon
-- (se houver) não é tocado.

revoke insert, update, delete on public.appointments        from anon;
revoke insert, update, delete on public.appointment_waitlist from anon;
