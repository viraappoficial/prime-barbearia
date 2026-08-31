# ST-1b.4 · Trava de linha nas RPCs de escrita de staff — Relatório do lab

status: **1 migration incremental (`20260831000400`) escrita e aplicada SÓ no
lab self-hosted. Produção intocada. Sem `db push`. Sem merge. Cutover
`20260829010000` intocado/bloqueado.**
branch: `staff/st-1b` (repo `prime-barbearia`), sobre `88065bf`
data: 2026-08-31
depende de: ST-H Gate 1 (`_staff_appt_for_write`, RPCs de status) + ST-1b.0–3.

---

## 1. Achado — corrida de concorrência

`staff_reschedule_appointment` (e as 5 RPCs de status da ST-H.4) resolviam a
linha por `_staff_appt_for_write(p_id, …)` — que faz `select … where id = p_id`
**sem lock** (`stable`) — e só **depois** a RPC atualizava o status.

Sob `READ COMMITTED`, duas requisições simultâneas sobre o **mesmo `p_id`**:

1. ambas leem o mesmo snapshot MVCC (status velho) e passam pela checagem;
2. o `update … where id = p_id` da 2ª sessão bloqueia no lock de linha da 1ª;
   ao destravar, o Postgres **re-casa** o `where` (só `id = p_id`, ainda
   verdadeiro) e **reaplica a escrita sem reavaliar o status** (que já foi
   checado contra o valor velho).

Efeitos:

| RPC | efeito da 2ª chamada concorrente |
|---|---|
| `staff_reschedule_appointment` | o antigo é cancelado 1×, mas o núcleo roda **2×** → **DOIS agendamentos ativos** de UMA origem (slots livres distintos; em dias distintos o advisory `agenda\|…` nem serializa) |
| `staff_accept_appointment` | **2ª notificação** `confirmado` ao cliente |
| `staff_cancel_appointment` | **2ª notificação** `cancelado-barbeiro` ao cliente |
| `staff_start_appointment` | sobrescreve `iniciado_em` em vez de `ALREADY_STARTED` |
| `staff_undo_start` | "desfaz" de novo, sem `BAD_TRANSITION` |

**Reprodução (lab, helper sem lock):** 2 `staff_reschedule_appointment` do
mesmo `p_id` para **dias distintos**, via processos `psql` concorrentes →
**10/10 iterações** com `heirs=2 wins=2` (dois agendamentos ativos a partir de
uma linha). A matriz R15/E19 da ST-1b cobria *duas linhas distintas disputando
um slot* — não *N chamadas sobre a mesma linha*.

---

## 2. Correção — `20260831000400_staff_write_row_lock.sql`

Migration **incremental** (não edita nenhuma migration já aplicada).

### Helper novo `_staff_appt_for_write_locked(p_id bigint, p_allow_vendas boolean)`

Idêntico ao `_staff_appt_for_write` porém:

- `volatile` (trava linha é efeito colateral — `stable` seria mentira);
- `security definer`, `set search_path = ''`, objetos `public.`/`auth.`
  qualificados, plpgsql estático (sem SQL dinâmico);
- `select * into v_appt from public.appointments where id = p_id **for update**`
  — a 2ª sessão **bloqueia aqui** até o commit da 1ª e então relê a versão nova;
- revalida **auth** (`auth.uid()` null → `NOT_AUTH`), **papel**
  (`barber_role()` null → `NOT_STAFF`) antes do lock, e **posse** (dono / admin /
  vendas-quando-permitido) **contra a linha já travada** — linha alheia →
  `NOT_FOUND` (não vaza posse), igual ao helper velho;
- `revoke execute … from public, anon, authenticated, service_role` — **sem
  grant**; só o owner (postgres) chama, de dentro das 6 RPCs.

`_staff_appt_for_write` (stable, sem lock) é **mantido** — inerte, sem grant
externo, sem chamador — só para o bloco de rollback da ST-H.4 seguir válido; um
`COMMENT ON FUNCTION` marca que foi substituído.

### 6 RPCs recriadas por `CREATE OR REPLACE`

`staff_reschedule_appointment`, `staff_accept_appointment`,
`staff_start_appointment`, `staff_undo_start`, `staff_no_show`,
`staff_cancel_appointment` — **corpo idêntico** exceto a troca
`_staff_appt_for_write` → `_staff_appt_for_write_locked`. Cada uma revalida o
status/`iniciado_em` **contra a linha travada** e só então escreve. Como o estado
lido já é o pós-commit da 1ª sessão, a 2ª cai no erro de domínio certo
(`NOT_RESCHEDULABLE` / `BAD_TRANSITION` / `ALREADY_STARTED`).

`CREATE OR REPLACE` **preserva os grants** — as 6 seguem
`execute … to authenticated` (reafirmado na migration como documentação
executável idempotente). Mensagens `raise … using errcode = 'P0001'` inalteradas.

### Ordem de locks — sem deadlock

A linha de `appointments` é travada **antes** de qualquer advisory lock. Só
`staff_reschedule_appointment` toma advisory (`agenda\|…` via
`_staff_insert_appointment`); as outras 5 não tomam nenhum. Não há ciclo. As
corridas da matriz (C1–C10, ~70 pares concorrentes) nunca produziram `40P01`.

Se uma 2ª sessão esperar além do `statement_timeout` do PostgREST (8s) → `57014`
→ a UI cai no genérico (`traduzErroStaff*` → `desconhecido`, "Tente de novo em
instantes"), sem vazar texto cru. As transações reais duram milissegundos.

### Rollback

`CREATE OR REPLACE` das 6 RPCs de volta ao corpo das migrations
`20260830000300` / `20260831000200` (chamando `_staff_appt_for_write`), depois
`drop function public._staff_appt_for_write_locked(bigint, boolean)` e
`comment on function public._staff_appt_for_write(bigint, boolean) is null`.
Está no cabeçalho da migration.

### Impacto no legado

**Nenhum.** O `#barberApp` segue no `UPDATE`/`INSERT` direto (o guard da ST-H
libera as colunas operacionais); nenhuma função legada chama estes helpers.

---

## 3. Mapa de erros da UI (`prime-next@domain/staff.ts`)

**Sem alteração necessária.** A migration **não introduz nenhum código de erro
novo**:

- `staff_reschedule_appointment` sob contenção → `NOT_RESCHEDULABLE` (já
  mapeado → `nao_remarcavel`: "Esse agendamento não pode ser remarcado agora.");
- `staff_accept_appointment` / `staff_start_appointment` sob contenção →
  `BAD_TRANSITION` / `ALREADY_STARTED` (já em `CODIGO_STAFF` →
  `transicao_invalida` / `ja_iniciado`).

O único cenário genuinamente novo é o timeout de contenção (`57014`), que **por
design** cai em `desconhecido` (a allowlist estrita só traduz `P0001` conhecido)
— e "Tente de novo em instantes" é a mensagem certa para contenção transitória.
Adicionar `57014` à allowlist violaria a disciplina do mapa (só `P0001`).

---

## 4. Matriz `28 OK / 0 FAIL` (`scripts/st1b4-concurrency-matriz.mjs`)

Corridas **reais** (processos `psql` separados via `Promise.all`, cada caso em
**loop** de 5–8 iterações para expor corrida latente). Sessões: cliente / barb A
(quarta de folga) / barb B / vendas / admin / **híbrido** (barbeiro **e**
cliente).

| caso | cenário | esperado | resultado |
|---|---|---|---|
| **L1** | S1 segura `FOR UPDATE`; S2 chama o helper **novo** (`lock_timeout=800ms`) | **bloqueia** → `55P03` (~≥800ms) | OK (864ms, "canceling statement due to lock timeout") |
| **L2** | idem, helper **velho** | retorna **na hora** (sem lock) | OK (65ms) |
| **C1** | 6× remarcar‖remarcar mesmo `p_id`, slots livres distintos | 1 vence, **1 herdeiro ativo**, antigo cancelado, perdedor `NOT_RESCHEDULABLE` | OK |
| **C1b** | 6× remarcar‖remarcar mesmo `p_id`, **dias distintos** (advisory não serializa) | o `FOR UPDATE` garante **1 herdeiro** | OK |
| **C1c** | 5× remarcar‖remarcar mesmo `p_id`, **mesmo slot** | 1 vence, perdedor `NOT_RESCHEDULABLE` (não `SLOT_TAKEN`), 1 herdeiro | OK |
| **C2** | 8× remarcar‖aceitar mesmo `p_id` | nunca 2 herdeiros; perdedor num `P0001` coerente (`NOT_RESCHEDULABLE`/`BAD_TRANSITION`) | OK |
| **C3** | 8× remarcar‖cancelar mesmo `p_id` | A cancelado; sem herdeiro-duplo; **sem notif dupla** | OK |
| **C4** | 8× aceitar‖aceitar mesmo `p_id` | 1 confirma, 1 `BAD_TRANSITION`, **EXATAMENTE 1 notificação** | OK |
| **C5** | 8× iniciar‖iniciar mesmo `p_id` | 1 inicia, 1 `ALREADY_STARTED` (não sobrescreve `iniciado_em`) | OK |
| **C6** | 6× desfazer‖desfazer | 1 desfaz, 1 `BAD_TRANSITION` | OK |
| **C7** | 8× no_show‖cancelar | 1 vence, 1 `BAD_TRANSITION`, ≤1 notif, status coerente | OK |
| **C8** | barb B remarca/aceita linha de A (concorrente e não) | `NOT_FOUND`, A intacto | OK |
| **C9** | cliente→`NOT_STAFF`; anon→`permission denied`; vendas cancel→`NOT_FOUND` (D4); vendas remarca→OK (D-1b-1) | — | OK |
| **C10** | híbrido remarca a **própria linha-como-cliente** (`staff_reschedule`); e corrida híbrido‖dono-B | `NOT_FOUND`; dono vence, 0 herdeiro | OK |
| **C11** | remarcar/aceitar/iniciar **sequenciais** (o lock não quebrou o caminho normal) | comportamento inalterado | OK |
| **EV** | `pg_proc`: helper novo `volatile`+`secdef`+`search_path=""`+só owner; 6 RPCs `secdef`+`search_path=""`+`volatile`+`grant authenticated`; 6 chamam o helper travado; `FOR UPDATE` presente | — | OK |

Prova end-to-end da correção: revertendo as RPCs ao helper sem lock, **C1b
falha 10/10**; re-aplicando `20260831000400`, **10/10 limpo**.

---

## 5. Regressões — todas verdes

| suíte | antes | depois |
|---|---|---|
| `scripts/agenda-lab-matriz.mjs` | 40 / 0 | **40 / 0** |
| `scripts/sth-gate1-matriz.mjs` (ST-H) | 158 / 0 | **158 / 0** |
| `scripts/st1b-lab-matriz.mjs` (ST-1b) | 84 / 0 | **84 / 0** |
| `scripts/st1b4-concurrency-matriz.mjs` (novo) | — | **28 / 0** |
| `prime-next` `npm run check` (151 testes) | 0 falhas | **0 falhas** |
| `prime-next` `npm run build` | ok | **ok** |
| `prime-next` `test:staff-lab` | 0 falhas | **0 falhas** |
| `prime-next` `test:staff-st1-lab` | 0 falhas | **0 falhas** |
| `prime-next` `test:staff-st1b-lab` | 0 falhas | **0 falhas** |
| `prime-next` `test:agenda-cliente-lab` | 0 falhas | **0 falhas** |
| `prime-next` `test:auth-lab` | 14 / 0 | **14 / 0** |
| `prime-next` `shots:staff` / `shots:staff-st1` / `shots:staff-st1b` (E2E+screenshots) | ok | **ok** |

---

## 6. Estado final do lab

- **37 appointments** (inalterado). Os **10 ativos** backfillados pela ST-1b.0
  (ids 16, 56, 60, 64, 65, 66, 69, 70, 71, 72) **permanecem** com `duration` =
  `45,105,30,45,45,45,30,30,45,110` — estado persistido do lab desde a ST-1b.0,
  **não** um baseline byte-idêntico ao dump de produção.
- **0 agendamentos ativos com `duration NULL`**.
- Migrations aplicadas no lab: ST-H.1–5, ST-1b.0–3, **ST-1b.4** (esta). Todas
  ficam aplicadas (rollout lab-first, igual à ST-H).
- `_staff_appt_for_write_locked` e as 6 RPCs travadas: `volatile` + `secdef` +
  `search_path=""` + `grant` só a `authenticated` (helper: só owner).
- Sem dado/objeto de teste desta tarefa. (7 usuários `*@prime-lab.local` de
  2026-08-28 são cruft pré-existente de sessões de auth/shots antigas — fora do
  escopo, não tocados.)
- **Produção Supabase, `master` do legado e cutover `20260829010000`:
  intocados.** Sem `db push`, sem merge.
