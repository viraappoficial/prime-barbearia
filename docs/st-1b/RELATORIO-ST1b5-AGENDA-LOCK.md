# ST-1b.5 · Protocolo canônico de lock de agenda — Relatório do lab

status: **1 migration incremental (`20260831000500`) aplicada SÓ no lab
self-hosted. Produção intocada. Sem `db push`. Sem merge. Cutover
`20260829010000` intocado/bloqueado. Aguarda nova revisão.**
branch: `staff/st-1b` (repo `prime-barbearia`), sobre `9f9a674` (ST-1b.4)
data: 2026-08-31

---

## 1. Os dois achados

### Achado 1 — chave advisory divergente (cross-surface cliente × staff)

|  | chave `pg_advisory_xact_lock` |
|---|---|
| `_insert_appointment` (cliente) | `hashtextextended(barber_id \|\| '\|' \|\| day, 0)` |
| `_staff_insert_appointment` (staff) | `hashtextextended('agenda\|' \|\| barber_id \|\| '\|' \|\| day, 0)` |

Chaves **diferentes** → `book_appointment` / `reschedule_appointment` do cliente
**não serializam** contra `staff_book_encaixe` / `staff_reschedule_appointment`.
Sem o cutover (exclusion constraint `appointments_no_overlap`), as duas escritas
concorrentes passam pela checagem manual de sobreposição contra o mesmo snapshot
e **criam agendamentos sobrepostos**.

**Reprodução no lab (helper com chave crua):** `book_appointment` do cliente ‖
`staff_book_encaixe` do staff, mesmo barbeiro/dia/slot, processos `psql`
concorrentes → **10/10 iterações** com `rows=2 wins=2` (duas linhas ativas no
mesmo slot).

### Achado 2 — inversão de ordem de lock (introduzida pela ST-1b.4)

| | ordem |
|---|---|
| ST-1b.4 `staff_reschedule_appointment` | linha (`FOR UPDATE`) → agenda (advisory) |
| `reschedule_appointment` do cliente | agenda (advisory, no núcleo) → linha (`UPDATE`) |

Não bastava trocar a chave: com a chave **unificada** mas as ordens **opostas**
sobre o mesmo `p_id`, o ciclo fecha → **deadlock `40P01`**.

**Reprodução no lab (chave canônica no cliente + staff ainda `linha→agenda`):**
`reschedule_appointment` do cliente ‖ `staff_reschedule_appointment`, mesmo
`p_id` → **`40P01` em 1/12 iterações** (timing-dependente, mas ocorre).

Com a chave crua ainda no cliente (achado 1 não corrigido) o mesmo par produz
**2 herdeiros** em vez de deadlock — as chaves distintas evitam o ciclo mas
deixam a corrida passar.

---

## 2. A correção — `20260831000500_agenda_lock_protocol.sql` (incremental)

### 2.1 `_lock_agenda(p_barber_id uuid, p_day date)` — helper canônico único

```sql
perform pg_catalog.pg_advisory_xact_lock(
  pg_catalog.hashtextextended('agenda|' || p_barber_id::text || '|' || p_day::text, 0)
);
```

`volatile`, `security definer`, `set search_path = ''`, objetos qualificados,
`revoke execute` de `public, anon, authenticated, service_role`, **sem grant** —
só o owner chama. É a **ÚNICA fonte da chave**. `pg_advisory_xact_lock` é
re-entrante por transação → uma RPC que trava a agenda no protocolo e depois
chama o núcleo (que retrava a mesma chave) não conflita consigo mesma.

### 2.2 Núcleos — `CREATE OR REPLACE`, só a linha do lock muda

- `_insert_appointment` (cliente): `pg_advisory_xact_lock(hashtextextended(barber||'|'||day,0))`
  → `perform public._lock_agenda(p_barber_id, p_day)`. **A chave do cliente muda**
  (ganha o prefixo `agenda|`) e passa a bater com a do staff. Resto idêntico.
- `_staff_insert_appointment` (staff): mesma troca; a chave já era `agenda|…` —
  só centraliza.

### 2.3 Protocolo canônico (a)-(d) — `reschedule_appointment` + `staff_reschedule_appointment`

Toda operação que toca **agenda + linha** obedece:

| passo | `reschedule_appointment` (cliente) | `staff_reschedule_appointment` (staff) |
|---|---|---|
| **(a)** authz mínima **sem lock**, só p/ descobrir barbeiro/dia-alvo | `auth.uid()`; `select client_id` unlocked → `NOT_FOUND` se não é dono. Destino = `p_barber_id`, `p_day` (parâmetros) | `auth.uid()` → `NOT_AUTH`; `barber_role()` → `NOT_STAFF`; `select barber_id` unlocked → `NOT_FOUND` se não é dono/admin/vendas. Destino = `(barber_id, p_day)` |
| **(b)** `_lock_agenda(barbeiro_alvo, dia_alvo)` — advisory da agenda de **destino** | `perform public._lock_agenda(p_barber_id, p_day)` | `perform public._lock_agenda(v_bid, p_day)` |
| **(c)** releitura `FOR UPDATE` + authz/estado revalidados **sob o lock** | `select * … for update` → `NOT_FOUND` / `NOT_RESCHEDULABLE` | `_staff_appt_for_write_locked(p_id, true)` (`FOR UPDATE` + authz completa) → `NOT_RESCHEDULABLE`; guarda `barber_id` imutável |
| **(d)** insert (`_*_insert_appointment`, retrava a mesma chave re-entrante) + cancela o antigo | idem | idem |

**Nunca linha → agenda.** `book_appointment` e `staff_book_encaixe` **não
mudam** — só inserem, então o lock canônico via o núcleo basta (não há linha
pré-existente a travar).

### 2.4 Ordem global de locks após a ST-1b.5 (sem ciclo)

```
reschedule (cliente/staff) : agenda(dest) → linha FOR UPDATE → agenda(dest) re-entrante (núcleo)
book_appointment           : agenda (núcleo)                       — não toca linha
staff_book_encaixe         : crm|tel → crm|nom → agenda (núcleo)    — não toca linha
accept/start/undo/no_show/cancel (staff, ST-1b.4) : só linha FOR UPDATE — não tocam agenda
```

Agenda **sempre** antes de linha; linha **nunca** antes de agenda. Sem ciclo.

### 2.5 Preservado

`SECURITY DEFINER`, `search_path=''`, objetos qualificados, `plpgsql` estático.
`CREATE OR REPLACE` preserva os grants (`book_appointment` /
`reschedule_appointment` / `staff_reschedule_appointment` → `authenticated`;
núcleos + `_lock_agenda` → só owner) — reafirmados na migration. Mensagens
`P0001` inalteradas. **Nenhum código de erro novo** → mapa estrito da UI
(`prime-next@domain/agenda.ts` `CODIGO_DOMINIO`, `domain/staff.ts`
`CODIGO_STAFF_AGENDA`) **sem alteração**. Nenhuma escrita direta no frontend.

### 2.6 Rollback

`CREATE OR REPLACE` das 4 funções de volta aos corpos de `20260829000200` /
`20260829000400` / `20260831000100` / `20260831000400`, depois
`drop function public._lock_agenda(uuid, date)`. No cabeçalho da migration.

### 2.7 Impacto no legado

Nenhum. O `#barberApp` segue no `UPDATE`/`INSERT` direto; nenhuma função legada
chama estes objetos.

---

## 3. Matriz `26 OK / 0 FAIL` (`scripts/st1b5-agenda-lock-matriz.mjs`)

Corridas **reais** (processos `psql` separados via `Promise.all`, cada caso em
loop de 8×). Sessões: 2 clientes-conta + 1 barbeiro-staff + admin.

| caso | cenário | resultado |
|---|---|---|
| **X0** | evidências: `_lock_agenda` volatile+secdef+`search_path=""`+só owner; os 2 núcleos chamam `public._lock_agenda`; nenhuma função usa a chave crua; os 2 reschedules põem `_lock_agenda` **antes** do `FOR UPDATE` | OK |
| **X1** | S1 segura `_lock_agenda(B,D)`: `pg_try_advisory` na chave canônica → `false` (tomada); na chave **crua** antiga → `true` (lock diferente); `book_appointment` do cliente **bloqueia** (lock timeout ~860ms); `staff_book_encaixe` **bloqueia** na MESMA chave | OK |
| **X1b** | `pg_locks` tem um advisory com `classid/objid` == `hashtextextended('agenda\|<barber>\|<dia>')` | OK |
| **X2** | 8× `book` (cliente) ‖ `encaixe` (staff) mesmo slot → **exatamente 1 vence**, 1 linha ativa, 1 `SLOT_TAKEN`, 0 `40P01` | OK |
| **X3** | 8× `book` (cliente) ‖ `staff_reschedule` p/ o mesmo slot → 1 ocupa; **se a remarca perde, o antigo fica ATIVO** (`SLOT_TAKEN` → rollback da RPC inteira); 0 `40P01` | OK |
| **X4** | 8× `reschedule` (cliente) ‖ `staff_reschedule` mesmo `p_id` — **mesmo dia** e **dias distintos** → sem deadlock, **exatamente 1 herdeiro**, antigo cancelado, perdedor num `P0001` coerente | OK |
| **X5** | 8× `reschedule` (cliente) ‖ `reschedule` (cliente) mesmo `p_id` — mesmo dia e dias distintos → sem deadlock, 1 herdeiro, perdedor `NOT_RESCHEDULABLE` | OK |
| **X6** | S1 segura `_lock_agenda(B,D)`: `staff_reschedule` e `reschedule` do cliente **bloqueiam na agenda** e **NÃO cancelam a linha** (prova de que o lock vem antes de qualquer escrita na linha) | OK |
| **X7** | sequencial: `book` normal, `reschedule` cliente normal, `staff_reschedule` normal; `SLOT_TAKEN` p/ slot ocupado (antigo intacto), `NOT_RESCHEDULABLE` p/ terminal, `PAST_DAY`, `STAFF_NOT_ALLOWED` | OK |

**Prova end-to-end:**

| estado | `book` cliente ‖ `encaixe` staff (mesmo slot) | `reschedule` cliente ‖ `staff_reschedule` (mesmo `p_id`) |
|---|---|---|
| chave crua + ST-1b.4 (`linha→agenda`) | **sobreposição 10/10** | 2 herdeiros (chaves distintas → sem ciclo, mas corrida passa) |
| chave canônica + ST-1b.4 (`linha→agenda`) | ok | **`40P01` 1/12** |
| **ST-1b.5 (chave canônica + protocolo `agenda→linha`)** | **0/10** | **0/12 deadlock, 1 herdeiro** |

---

## 4. Regressões — todas verdes

| suíte | resultado |
|---|---|
| `scripts/agenda-lab-matriz.mjs` | **40 / 0** |
| `scripts/sth-gate1-matriz.mjs` (ST-H) | **158 / 0** |
| `scripts/st1b-lab-matriz.mjs` (ST-1b) | **84 / 0** |
| `scripts/st1b4-concurrency-matriz.mjs` (ST-1b.4) | **28 / 0** |
| `scripts/st1b5-agenda-lock-matriz.mjs` (ST-1b.5, novo) | **26 / 0** |
| `prime-next` `npm run check` | **151 testes, 0 falhas** |
| `prime-next` `npm run build` | **ok** |
| `test:staff-lab` / `test:staff-st1-lab` / `test:staff-st1b-lab` / `test:agenda-cliente-lab` | **0 falhas** |
| `test:auth-lab` | **14 / 0** |
| E2E + screenshots `shots:staff` / `shots:staff-st1` / `shots:staff-st1b` | **ok** |

---

## 5. Estado final do lab

- **37 appointments** · **0 ativos com `duration NULL`**.
- Os 10 ativos backfillados pela ST-1b.0 (ids 16, 56, 60, 64, 65, 66, 69, 70,
  71, 72) permanecem com `duration = 45,105,30,45,45,45,30,30,45,110` — estado
  persistido do lab desde a ST-1b.0, **não** baseline byte-idêntico ao dump de
  produção.
- Migrations aplicadas: ST-H.1–5, ST-1b.0–3, ST-1b.4, **ST-1b.5** (esta).
- `_lock_agenda`, os 2 núcleos e os 2 reschedules: `volatile` + `secdef` +
  `search_path=""`; grant só a `authenticated` nas RPCs públicas, só owner nos
  helpers/núcleos.
- Sem dado/objeto de teste desta tarefa. (7 usuários `*@prime-lab.local` de
  2026-08-28 são cruft pré-existente de sessões antigas — fora do escopo.)
- **Produção Supabase, `master` do legado, cutover `20260829010000`:
  intocados.** Sem `db push`. Sem merge.

---

## 6. Escopo NÃO tocado (candidatos a fatia futura)

- `cancel_appointment` (cliente) tem o mesmo padrão "lê sem lock → update" que as
  RPCs de status do staff tinham antes da ST-1b.4 — uma 2ª chamada concorrente
  insere uma **2ª notificação** ao barbeiro. Não toca agenda (só flip de status
  numa linha) → um `FOR UPDATE` na releitura resolve. Fora do escopo declarado
  desta tarefa (chave canônica + os 2 reschedules).
