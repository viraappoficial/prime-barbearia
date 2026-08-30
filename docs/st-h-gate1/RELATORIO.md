# ST-H · Gate 1 — Relatório

status: **migrations escritas e aplicadas SÓ no lab self-hosted. Produção
intocada. Sem `db push`. Sem merge. Sem cutover de agenda.**
branch: `staff/st-h-gate1` (repo `prime-barbearia`), sobre `7b60d9d`
data: 2026-08-30 · **rev. 1 (30/08): +ST-H.3b (achado do Codex — usuário híbrido)**
proposta: `prime-next@proposta/staff-hardening:docs/investigacoes/05-staff-hardening.md`
Gate 0: `prime-next@proposta/staff-hardening` `d53d8e0` (`79 OK / 0 FAIL`)

**Resultado da matriz: `158 OK / 0 FAIL`** (`scripts/sth-gate1-matriz.mjs`).
Lab volta a **37 appointments**, sem objeto/dado de teste.

> **rev. 1 — revisão do Codex ao Gate 1.** O guard escolhia o allow-list só por
> `barber_role()`. Um usuário **barbeiro + cliente**, com agendamento próprio
> marcado com OUTRO barbeiro (`client_id=auth.uid()` ∧ `barber_id<>auth.uid()`),
> passava pela RLS `clients_update_own` mas era tratado como staff → editava
> `discount_price`/`services`/data/`notes` da própria linha. **Furo provado no
> lab.** Corrigido por **migration incremental** `20260830000250` (não altera a
> `…000200` já aplicada): o guard distingue *"barbeiro operando SUA agenda"*
> (`OLD.barber_id = auth.uid()` → staff) de *"barbeiro agindo como cliente"*
> (`OLD.barber_id <> auth.uid()` → cliente). admin/vendas mantêm o caminho de
> staff (escopo global deliberado das policies). SH32 cobre (15 asserções).

---

## 1. Numeração

Última migration no repo: `20260829010000_agenda_cutover.sql` (bloqueada, não
aplicada). Data corrente 2026-08-30 → prefixo livre **`20260830`** (não `2026090*`
como a proposta chutou). Ordena **depois** de todas as de agenda; a ST-H **não**
depende do cutover e **não** o toca.

| # | arquivo | o quê |
|---|---|---|
| ST-H.1 | `20260830000000_barber_role.sql` | helper `barber_role()` |
| ST-H.2 | `20260830000100_policies_appointments_crm_via_role.sql` | 8 policies de papel → `barber_role()` |
| ST-H.3 | `20260830000200_appointments_col_guard.sql` | camada 1 (grant 16 col) + camada 2 (trigger) |
| **ST-H.3b** | `20260830000250_appointments_guard_hybrid.sql` | **rev.1** — `create or replace` do guard: distingue barbeiro-staff × barbeiro-como-cliente |
| ST-H.4 | `20260830000300_staff_status_rpcs.sql` | 5 RPCs de status |
| ST-H.5 | `20260830000400_higiene_grants_staff.sql` | higiene de grants |

`git diff 7b60d9d..HEAD --stat` (path-limited, o branch só tem estes arquivos):
migrations `20260830000000..20260830000400` (5) + `20260830000250` (rev.1) +
`scripts/sth-gate1-matriz.mjs` + `docs/st-h-gate1/RELATORIO.md`.

---

## 2. O que cada migration faz

### ST-H.1 — `public.barber_role()`
`sql stable security definer set search_path=''`, owner `postgres` (bypassa a RLS
de `barbers`). Devolve o papel do próprio `auth.uid()` ou `null`.
`revoke execute … from public, anon, authenticated, service_role` → `grant
execute … to anon, authenticated` (as policies `TO public` da ST-H.2 são avaliadas
p/ `anon`; sem EXECUTE, erraria `permission denied for function`). Inerte sozinha.

### ST-H.2 — policies de papel via `barber_role()`
`ALTER POLICY` (não drop+create) das **8** policies que inlinam `EXISTS(select …
from barbers where … role = '…')`:

| tabela | policies |
|---|---|
| `appointments` | `admin_select_all`, `admin_update_all`, `appointments_vendas_insert`, `appointments_vendas_read`, `appointments_vendas_update` |
| `crm_clients` | `crm_clients_admin_select_all`, `crm_clients_vendas_insert`, `crm_clients_vendas_read` |

`EXISTS(... role='admin')` → `barber_role() = 'admin'` (idem `'vendas'`).
Comportamento **idêntico** (para `anon`: `null = 'admin'` → false, igual ao
`EXISTS`). As `barbers_*_own` / `clients_*_own` / `crm_clients_*_own` (usam
`barber_id/client_id = auth.uid()`) **não são tocadas**.
**`is_barber_staff()` NÃO é reescrito** — é usado por ~15 policies fora do escopo
da ST-H (D-H1: só `appointments` + `crm_clients` agora).

### ST-H.3 — guard de colunas de `appointments`

**Camada 1 (grant).** `revoke update on public.appointments from anon,
authenticated` + `grant update (<16 colunas>) to authenticated`.
As **16**: `status, iniciado_em, day, day_label, time, duration, services,
discount_price, notes, rating, rating_comment, rating_by, client_rating,
client_rating_comment, barber_reply, reminder_sent_at`.
São a **união real** dos allow-lists por papel (§5.4). A proposta §5.3 listou 15 e
a §9 falou em "19" — ambas frouxas; a conciliação está no cabeçalho da migration.
`notes` entra (barbeiro grava observação); as 3 de avaliação do cliente entram
porque o cliente é `authenticated`.
Nunca no grant (8 estruturais): `id, client_id, barber_id, client_name,
client_email, is_encaixe, coupon_code, created_at` → PATCH nelas = **403 no grant**,
antes do trigger.

**Camada 2 (trigger `_appointments_guard_update`).** `SECURITY INVOKER`
(`prosecdef=false`), `search_path=''`, `BEFORE UPDATE FOR EACH ROW`.
- passo 1: `current_user in ('postgres','supabase_admin','service_role')` →
  `return new` (RPCs `SECURITY DEFINER` de owner e backend fazem a própria
  validação — os 3 `current_user` **medidos** no Gate 0 e re-medidos aqui, SH2b).
- delta **dinâmico** por `jsonb_each(to_jsonb(new))` vs `old` → coluna futura é
  default-deny automaticamente. Delta vazio → `return new` (no-op).
- **cliente** (`barber_role() is null`; a RLS `clients_update_own` já garante que
  é o dono): vocabulário inteiro = `{status, rating, rating_comment, rating_by}`.
  Qualquer coluna fora → `CLIENT_COL_FORBIDDEN`. `status` no delta → tem que ser
  **só** `status`, de `{pendente,confirmado}` p/ `cancelado` → senão
  `CLIENT_STATUS_FORBIDDEN`. Senão (delta ⊆ avaliação) → `rating` **de fato** no
  delta ∧ `OLD.status='concluido'` ∧ `OLD.rating IS NULL` ∧ `NEW.rating ∈ [1,5]`
  ∧ `NEW.rating_by='cliente'` → senão `CLIENT_RATING_FORBIDDEN`.
- **staff** (barbeiro/vendas/admin, D-H11 mesmo conjunto): delta ⊆ `{status,
  iniciado_em, day, day_label, time, duration, services, discount_price, notes,
  client_rating, client_rating_comment, barber_reply, reminder_sent_at}` → senão
  `STAFF_COL_FORBIDDEN`. `rating/rating_comment/rating_by` são do cliente → staff
  é barrado nelas **pelo trigger**, mesmo estando no grant.

**Endurecimento sobre o Gate 0 (documentado):** o protótipo do Gate 0 tinha 2
brechas latentes não exercitadas — (a) `rating_comment`/`rating_by` sozinhos (sem
`rating` no delta) passavam por propagação de `null`; (b) `rating` sem
`rating_by='cliente'` passava. O guard da migration fecha as duas
(`'rating' = any(v_changed)` + `coalesce(…, false)`). SH6e cobre.

### ST-H.3b — guard: barbeiro-staff × barbeiro-como-cliente (rev.1, achado do Codex)

`20260830000250_appointments_guard_hybrid.sql` — `create or replace` **só** de
`_appointments_guard_update()` (o trigger e os grants da `…000200` ficam; a
migration aplicada **não** é tocada).

**Furo (provado no lab):** usuário com linha em `barbers(role='barbeiro')` **e**
em `clients`, dono de um agendamento marcado com OUTRO barbeiro (`client_id =
auth.uid()` ∧ `barber_id <> auth.uid()`): passa no `USING` por
`clients_update_own` (a `barbers_update_own` exige `barber_id = auth.uid()`),
mas o guard escolhia o allow-list por `barber_role()` = `'barbeiro'` → **caminho
de staff** → editava `discount_price`/`services`/`day`/`time`/`notes` da própria
linha.

**Correção — a decisão agora é por posse da linha, não só por papel:**

| condição | caminho |
|---|---|
| `barber_role()` is null | CLIENTE |
| `barber_role()='barbeiro'` ∧ `OLD.barber_id = auth.uid()` | STAFF operacional |
| `barber_role()='barbeiro'` ∧ `OLD.barber_id <> auth.uid()` | **CLIENTE** (só chegou por `clients_update_own`) |
| `barber_role()` in (`admin`,`vendas`) | STAFF (escopo global deliberado das policies `admin_update_all` / `appointments_vendas_update`) |

As RPCs `SECURITY DEFINER` de staff **não mudam**: `_staff_appt_for_write` já
checa posse (`v_appt.barber_id = auth.uid() OR admin [OR vendas]`) — um híbrido
chamando `staff_accept` sobre a própria linha-como-cliente recebe `NOT_FOUND`
(SH32.4).

Rollback da ST-H.3b: reaplicar o corpo de `…000200` (guard sem `v_as_client`).
Rollback completo (harness): `drop trigger … ; drop function …` cobre as duas.

### ST-H.4 — RPCs de status
`_staff_appt_for_write(p_id, p_allow_vendas)` (helper `security definer`, sem
grant a role externa) resolve `appt` + valida `auth.uid()` (`NOT_AUTH`) +
`barber_role() is not null` (`NOT_STAFF`) + posse (dono, ou admin, ou vendas se
`p_allow_vendas`) → `NOT_FOUND` (não vaza posse alheia).

| RPC | transição | posse | notif |
|---|---|---|---|
| `staff_accept_appointment(p_id)` | `pendente → confirmado` | dono/admin/vendas | `confirmado` ao cliente |
| `staff_start_appointment(p_id)` | `confirmado` ∧ `iniciado_em null` → `now()` | dono/admin/vendas | — |
| `staff_undo_start(p_id)` | `iniciado_em → null` | dono/admin/vendas | — |
| `staff_no_show(p_id)` | `{pendente,confirmado} → nao_compareceu` | dono/admin/vendas | — |
| `staff_cancel_appointment(p_id, p_motivo)` | `{pendente,confirmado} → cancelado` | **dono/admin** (D4) | `cancelado-barbeiro` ao cliente |

Erros: `NOT_AUTH, NOT_STAFF, NOT_FOUND, BAD_TRANSITION, ALREADY_STARTED`
(`errcode='P0001'`). Todas `security definer`, `search_path=''`, objetos `public.`
qualificados, notif na transação, sem SQL dinâmico. `revoke execute … from
public, anon, authenticated, service_role` → `grant execute … to authenticated`.

### ST-H.5 — higiene (D-H7)
`revoke insert, update, delete on public.appointments from anon` (idempotente — o
lab já veio da `20260829000600`; produção não) + `revoke truncate, trigger,
references on public.appointments, public.crm_clients, public.notifications from
anon, authenticated`.

---

## 3. Objetos finais no lab

### `pg_proc`
```
_appointments_guard_update  sec=INVOKER  cfg=search_path=""
_staff_appt_for_write       sec=DEFINER  cfg=search_path=""
barber_role                 sec=DEFINER  cfg=search_path=""
staff_accept_appointment    sec=DEFINER  cfg=search_path=""
staff_cancel_appointment    sec=DEFINER  cfg=search_path=""
staff_no_show               sec=DEFINER  cfg=search_path=""
staff_start_appointment     sec=DEFINER  cfg=search_path=""
staff_undo_start            sec=DEFINER  cfg=search_path=""
```

### EXECUTE grants
```
barber_role               → anon, authenticated, postgres
staff_*  (as 5)           → authenticated, postgres           (SEM anon)
_appointments_guard_update → postgres                         (SEM anon/authenticated)
_staff_appt_for_write     → postgres
```

### `appointments` — grants de tabela (antes → depois)
```
anon:          SELECT,REFERENCES,TRIGGER,TRUNCATE        →  SELECT
authenticated: ALL (7)                                   →  DELETE,INSERT,SELECT
postgres / service_role:  ALL (7)                        →  (inalterado)
```
UPDATE por coluna de `authenticated`: **as 16** listadas na §2 (nada estrutural).

> **DELETE de `authenticated` fica** (a proposta não escopou revogar; sem policy
> de DELETE → a RLS já nega). Idem `crm_clients`/`notifications` mantêm
> `INSERT/UPDATE/DELETE` de `anon`/`authenticated` (RLS nega; aperto = higiene do
> CRM na ST-3, D-H5/D-H6). ST-H.5 só tirou truncate/trigger/references delas.

### triggers em `appointments`
```
appointments_fill_duration  BEFORE INSERT  (inalterado, agenda)
appointments_guard_update   BEFORE UPDATE FOR EACH ROW  EXECUTE _appointments_guard_update()   ← novo
```
`_appointments_guard_update` no lab = corpo da **rev.1** (`…000250`): `declare`
inclui `v_as_client`; a escolha do allow-list é `v_role is null OR (v_role =
'barbeiro' AND old.barber_id IS DISTINCT FROM auth.uid())`. Definição completa no
dump de evidências do harness.

### policies (contagem e comando inalterados; 8 agora chamam `barber_role()`)
```
appointments . admin_select_all             USING  barber_role() = 'admin'
appointments . admin_update_all             USING  barber_role() = 'admin'
appointments . appointments_vendas_insert   CHECK  barber_role() = 'vendas'
appointments . appointments_vendas_read     USING  barber_role() = 'vendas'
appointments . appointments_vendas_update   USING  barber_role() = 'vendas'
appointments . barbers_*_own / clients_*_own    (inalteradas — barber_id/client_id = auth.uid())
crm_clients  . crm_clients_admin_select_all  USING  barber_role() = 'admin'
crm_clients  . crm_clients_vendas_insert     CHECK  barber_role() = 'vendas'
crm_clients  . crm_clients_vendas_read       USING  barber_role() = 'vendas'
crm_clients  . crm_clients_*_own                (inalteradas)
```

---

## 4. `current_user` re-medido (SH2b — sonda efêmera, guard real intacto)

| caminho | `current_user` \| `current_role` \| `session_user` | guard passo 1 |
|---|---|---|
| REST authenticated (barbeiro) | `authenticated \| authenticated \| authenticator` | avalia papel |
| REST authenticated (cliente) | `authenticated \| authenticated \| authenticator` | avalia papel |
| `SET ROLE service_role` | `service_role \| service_role \| postgres` | **bypass** |
| RPC `SECURITY DEFINER` (owner) via REST | `postgres \| postgres \| authenticator` | **bypass** |
| `psql -U postgres` | `postgres \| postgres \| postgres` | **bypass** |
| RPC `SECURITY INVOKER` via REST | `authenticated \| authenticated \| authenticator` | avalia papel (**não** bypassa) |

(Chave `service_role` real não extraída — `SET ROLE service_role` reproduz o
`current_user` que o PostgREST assume com JWT `role=service_role`, que é tudo que
o guard lê.)

---

## 5. Matriz SH1–SH32 (`158 OK / 0 FAIL`)

`141` na rev.0 + **17** da SH32 (usuário híbrido).

| SH | o quê | resultado |
|---|---|---|
| **SH1** | `barber_role()` p/ barbeiro/vendas/admin/cliente/anon | `barbeiro`/`vendas`/`admin`/`null`/`null` — anon **sem** `permission denied` |
| **SH2** | leitura de admin/vendas/barbeiro/cliente após ST-H.2 | preservada; `test:staff-lab` (A/B/C/D) **0 falhas** |
| **SH2b** | `current_user` nos 6 caminhos | bate com a §4 |
| **SH3** | cliente PATCH `discount_price`/`services`/`day`+`time`/`day_label`/`duration`/`notes`/`iniciado_em`/`client_rating`/`barber_reply`/`reminder_sent_at` | **400 `CLIENT_COL_FORBIDDEN`** |
| **SH3** | cliente PATCH `barber_id`/`is_encaixe`/`coupon_code`/`created_at` | **403** (camada 1) |
| **SH4** | cliente `status → confirmado/concluido/nao_compareceu` | **400 `CLIENT_STATUS_FORBIDDEN`** |
| **SH5** | cliente `status → cancelado` de `pendente`/`confirmado` | **204** |
| **SH5b** | cliente `cancelado` de `concluido`/`nao_compareceu` | **400 `CLIENT_STATUS_FORBIDDEN`** |
| **SH5b** | cliente `cancelado` de `cancelado` | **204 no-op** (delta vazio; linha inalterada) |
| **SH6** | cliente `rating=5`+`rating_by='cliente'` em `concluido` s/ nota | **204** (1×) |
| **SH6b** | `rating` em `pendente`/`confirmado` | **400 `CLIENT_RATING_FORBIDDEN`** |
| **SH6c** | re-avaliar (`OLD.rating` presente) | **400 `CLIENT_RATING_FORBIDDEN`** |
| **SH6d** | `rating=0`/`6`; `rating_by='barbeiro'` | **400 `CLIENT_RATING_FORBIDDEN`** |
| **SH6e** | `rating` sem `rating_by`; `rating_comment` sozinho; `rating_by` sozinho | **400 `CLIENT_RATING_FORBIDDEN`** (brecha do Gate 0 fechada) |
| **SH6e** | `rating`+`discount_price` | **400 `CLIENT_COL_FORBIDDEN`** |
| **SH6e** | `status=cancelado`+`barber_id` | **403** (camada 1), `status` não muda |
| **SH7** | cliente `client_id`/`client_name`/`client_email` | **403** (camada 1) |
| **SH8** | barbeiro dono: `status`/`iniciado_em`/`day`+`time`/`duration`/`services`+`discount_price`/`notes`/`client_rating`/`barber_reply`/`reminder_sent_at` | **204** (`#barberApp` segue) |
| **SH9** | barbeiro: `client_id`/`barber_id`/`is_encaixe`/`coupon_code` | **403** (camada 1) |
| **SH9** | barbeiro: `rating`/`rating_by`/`rating_comment` (nota do cliente) | **400 `STAFF_COL_FORBIDDEN`** |
| **SH10** | barbeiro B numa linha do barbeiro A | linha **não muda** (RLS `barbers_select_own`) |
| **SH11** | vendas: `status`/`notes`/`services`+`discount_price` OK; `barber_id`/`is_encaixe` 403; `rating` `STAFF_COL_FORBIDDEN` | conforme |
| **SH12** | admin: `status`+`discount_price`/`notes`/`day`+`time` OK; `client_id`/`barber_id`/`is_encaixe` 403; `rating` `STAFF_COL_FORBIDDEN` | conforme |
| **SH13/SH26** | `staff_accept` (DEFINER) muda `status` — guard bypassado; `link_precadastro` (DEFINER) ainda executa | OK |
| **SH14** | `staff_accept` `pendente→confirmado` + **1** notif `client`/`confirmado` na transação | OK |
| **SH15** | `staff_accept` de não-`pendente` | `BAD_TRANSITION` |
| **SH16** | `staff_accept`/`staff_cancel` de linha de outro barbeiro (não-admin) | `NOT_FOUND` |
| **SH17** | `staff_start` → `iniciado_em`; 2× → `ALREADY_STARTED`; `staff_undo_start` → `null`; 2× → `BAD_TRANSITION` | OK |
| **SH18** | `staff_no_show` → `nao_compareceu` **sem** notif; `staff_cancel(dono,motivo)` → `cancelado` + notif `cancelado-barbeiro` | OK |
| **SH19** | admin chama qualquer `staff_*`; vendas chama `staff_accept` OK; vendas chama `staff_cancel` → `NOT_FOUND` (D4) | conforme |
| **SH20** | cliente chama `staff_accept` | `NOT_STAFF` |
| **SH21** | legado STAFF via REST: `baAcceptAppt`, `baMarcarNaoCompareceu`, `baIniciarAtendimento`, `baConfirmRemarcar`, `baCartSalvarServico`, feedback do barbeiro, `baSaveReply`, `baMarcarLembreteEnviado` | **todos 204** |
| **SH22** | legado CLIENTE via REST: `caDoCancel`, feedback do cliente | **204** |
| **SH23** | grants: `barber_role`→anon,authenticated; `staff_*`→authenticated; guard INVOKER + `search_path=""`, sem grant a anon/authenticated; UPDATE = 16 colunas; anon só SELECT | conforme |
| **SH24** | `TRUNCATE` (authenticated) / `INSERT`,`UPDATE` (anon) | `permission denied` (42501) |
| **SH25** | 11 policies em `appointments` (contagem inalterada); 8 usam `barber_role()`; nenhuma de `appointments`/`crm_clients` ainda inlina `from barbers` | conforme |
| **SH27** | coluna futura (`_sth_teste`): sem grant → 403; **com** grant → cliente `CLIENT_COL_FORBIDDEN`, barbeiro `STAFF_COL_FORBIDDEN` (default-deny nas 2 camadas) | OK |
| **SH28** | smoke legado cliente ponta a ponta: INSERT direto (`clients_insert_own`) + `caDoCancel` + feedback | **passa** |
| **SH29** | smoke legado barbeiro: aceitar→iniciar→remarcar in-place→serviço+desconto→feedback→reply→lembrete | **passa** |
| **SH30** | smoke legado vendas: `appointments_vendas_insert` + PATCH `status` passa; PATCH `barber_id` → 403 | conforme |
| **SH31** | smoke legado admin: `admin_update_all` PATCH `status`/`discount_price`/`notes` passa; `client_id`/`barber_id` → 403 | conforme |
| **SH32** | **usuário HÍBRIDO** (barbeiro + cliente): |
| SH32 | `barber_role(híbrido)` = `barbeiro` | conforme |
| SH32.1 | híbrido como cliente de OUTRO barbeiro (`OLD.barber_id<>uid`): `discount_price`/`services`/`day`+`time`/`notes` | **400 `CLIENT_COL_FORBIDDEN`** |
| SH32.1 | híbrido-como-cliente: `status → confirmado` | **400 `CLIENT_STATUS_FORBIDDEN`** |
| SH32.1 | híbrido-como-cliente: cancelar o próprio ativo; avaliar 1× o corte concluído | **204** (regras de cliente) |
| SH32.2 | híbrido na PRÓPRIA agenda (`OLD.barber_id=uid`): `status`/`services`+`discount_price`/`day`+`time`/`notes` | **204** (staff operacional) |
| SH32.2 | híbrido na própria agenda: `client_id` | **403** (camada 1) |
| SH32.3 | híbrido numa linha totalmente alheia | **RLS** — 0 linhas, nada muda |
| SH32.4 | híbrido `staff_accept` na própria agenda OK; na linha-como-cliente → `NOT_FOUND` | conforme (posse do RPC inalterada) |
| regressão | `agenda-lab-matriz` (40/40) + `staff-lab-test` (A/B/C/D) | **0 falhas** |

Saída completa: `scripts/sth-gate1-matriz.mjs` (roda tudo + limpa + evidências).

---

## 6. Prova das exigências

**Cliente NÃO altera fora do fluxo permitido:**
- preço (`discount_price`) → SH3 `CLIENT_COL_FORBIDDEN` / SH6e
- serviço (`services`) → SH3 `CLIENT_COL_FORBIDDEN`
- data/hora (`day`/`day_label`/`time`) → SH3 `CLIENT_COL_FORBIDDEN`
- barbeiro (`barber_id`) → SH3 403 (camada 1)
- status (≠ cancelar ativo) → SH4/SH5b `CLIENT_STATUS_FORBIDDEN`
- avaliação (re-avaliar, sem `rating_by`, comentário solto, fora de `concluido`,
  fora de 1..5) → SH6b–SH6e `CLIENT_RATING_FORBIDDEN`
- **inclusive quando o cliente é um barbeiro logado** editando o próprio corte
  com um colega (`OLD.barber_id <> auth.uid()`) → SH32.1 (rev.1)
- só passa: `status → cancelado` de ativo (SH5/SH32.1) e avaliar 1× o próprio
  corte concluído (SH6/SH32.1).

**Barbeiro NÃO altera:**
- cliente/barbeiro da linha (`client_id`/`barber_id`) → SH9 403
- encaixe (`is_encaixe`) → SH9 403
- cupom (`coupon_code`) → SH9 403
- nota do cliente (`rating`/`rating_by`/`rating_comment`) → SH9 `STAFF_COL_FORBIDDEN`
- linha de outro barbeiro → SH10 (RLS)
- só passa: o conjunto operacional do `#barberApp` (SH8) — até a ST-2 apertar
  `services`/`discount_price`/`client_rating*`.

**Fluxos críticos do legado via REST/PostgREST** (não só SQL): SH21, SH22, SH28,
SH29, SH30, SH31 — todos com token real por papel, `PATCH`/`POST` no PostgREST.

**Caminhos DEFINER/INVOKER:** SH13/SH26 (DEFINER bypassa), SH2b linha 6 +
`_sthg1_invoker` (INVOKER **não** bypassa).

---

## 7. Rollback (por migration, testado)

Cada arquivo tem o rollback no cabeçalho. O harness executa o ciclo completo
**reverter → verificar baseline → re-aplicar** e confere: funções ST-H removidas,
trigger removido, `authenticated` volta a ter `UPDATE` tabela-inteira,
`admin_update_all` volta ao `EXISTS` inline. Ordem de reversão: ST-H.5 → .4 →
.3b/.3 → .2 → .1 (as RPCs antes do helper; o trigger antes da função; as policies
antes de dropar `barber_role()`).

ST-H.3b sozinha reverte reaplicando o corpo de `…000200`. O `drop trigger … ;
drop function _appointments_guard_update()` do rollback completo cobre `…000200`
e `…000250` (é um único objeto, `create or replace`).

Consolidado em `scripts/sth-gate1-matriz.mjs` (`ROLLBACK_SQL`).

---

## 8. Impacto no legado

**Nenhuma regressão medida.** O `#barberApp` continua escrevendo direto as 16
colunas operacionais (SH8/SH21/SH29). O `#clientApp` continua cancelando e
avaliando (SH22/SH28). O que **muda de propósito**: o cliente perde a capacidade
(hoje real — §5.2-bis, HTTP 200) de editar preço/serviço/data/barbeiro/status/
re-avaliação da própria linha via PostgREST.

Duas RLS (`clients_update_own`, `barbers_update_own`) continuam com `GRANT`
compartilhado (`authenticated`) — o cutover de staff (dropar `barbers_update_own`
etc.) é frente futura, fora da ST-H.

---

## 9. Fora do escopo (confirmado — D-H2..D-H7)

- `_staff_insert_appointment` + `staff_reschedule_appointment` + `staff_book_encaixe`
  → **ST-1**.
- `staff_complete_appointment` + RPC de checkout + o guard passa a rejeitar
  `services`/`discount_price`/`client_rating*` p/ staff → **ST-2**.
- `staff_reply_review` + `revoke update (barber_reply)` → **ST-3**.
- `clients_readable_by_barbers` (curadoria) → **ST-3** (D-H5).
- `notifications_insert_staff` (aperto) → cutover de staff (D-H6).
- `is_barber_staff()` reescrito + demais tabelas de gestão → por fatia (D-H1).
- higiene de `INSERT/UPDATE/DELETE` de `anon` em `crm_clients`/`notifications` →
  higiene do CRM (ST-3).
- `revoke DELETE` de `authenticated` em `appointments` → não escopado (RLS já nega).

---

## 10. Próximos gates (proposta §9)

- **Gate 2** — revisão conjunta Codex + Gabriel deste diff + evidências.
- **Gate 3** — autorização explícita do Gabriel p/ produção, em janela, rollback à
  mão.
- **Gate 4** — aplicar em produção + re-rodar a matriz contra produção.

A **ST-1 pode ser construída no lab em paralelo** já (D9 não exige produção).
