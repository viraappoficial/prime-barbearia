# ST-1b · Remarcar + Encaixe do staff — Relatório do lab

status: **4 migrations escritas e aplicadas SÓ no lab self-hosted. Produção
intocada. Sem `db push`. Sem merge. Sem cutover de agenda
(`20260829010000` segue bloqueada).**
branch: `staff/st-1b` (repo `prime-barbearia`), sobre `a0ac3b7`
data: 2026-08-31
proposta (aprovada, 3 revisões): `prime-next@proposta/staff-st1b:docs/investigacoes/08-staff-st1b-remarcar-encaixe.md`
depende de: ST-H Gate 1/2 no lab (`barber_role()`, guard de colunas,
`_staff_appt_for_write`, RPCs de status) + agenda (`_hhmm_to_min`,
`_validate_services`, `_barber_covers`, `shop_settings`, `normalize_phone_br`,
`crm_clients`).

**Resultado da matriz: `84 OK / 0 FAIL`** (`scripts/st1b-lab-matriz.mjs` —
G0 + R1–R20 + E1–E27, incl. E27b domingo). 1 caso (E18 hoje-passado) é
**time-of-day-dependente** e ficou `SKIP` (o relógio do lab estava 00:49; o
PAST_DAY determinístico via "ontem" cobre o caminho).

Regressões, todas verdes:

| suíte | resultado |
|---|---|
| `scripts/st1b-lab-matriz.mjs` (ST-1b) | **84 OK / 0 FAIL** |
| `scripts/agenda-lab-matriz.mjs` | **40 OK / 0 FAIL** |
| `scripts/sth-gate1-matriz.mjs` (ST-H) | **158 OK / 0 FAIL** |
| `prime-next` `test:staff-lab` | **0 falhas** |
| `prime-next` `test:staff-st1-lab` | **0 falhas** |

Lab termina com **37 appointments**, **0 ativos com `duration NULL`**, sem
objeto/dado de teste. As 4 funções novas ficam **aplicadas** (mesmo rollout
lab-first da ST-H).

> **Nota sobre os 37.** A `ST-1b.0` fez o backfill dirigido de `duration` nos
> **10 agendamentos ativos** que estavam `NULL` (ids 16, 56, 60, 64, 65, 66, 69,
> 70, 71, 72). A contagem de linhas **não muda** (segue 37) — o que muda é que
> esses 10 agora têm `duration` = soma real do catálogo
> (`45,105,30,45,45,45,30,30,45,110`). Isso é permanente e desejado: a checagem
> de sobreposição de intervalo da ST-1b nunca pode tocar `NULL`.

---

## 1. Numeração

Última migration real aplicada: `20260830000400` (ST-H.5). Data corrente
2026-08-31 → prefixo **`20260831`**. Ordena **depois** de toda a ST-H; a ST-1b
**não** depende do cutover (`20260829010000`) e **não** o toca.

| # | arquivo | o quê | rollback |
|---|---|---|---|
| **ST-1b.0** | `20260831000000_backfill_active_duration.sql` | `do $$…$$` sempre-presente: preflight de ativos `duration NULL` → **no-op registrado** / **backfill dirigido** (soma do catálogo) / **aborta** listando ids. Sem fallback `slot_min`. Não põe `NOT NULL`. | irreversível por natureza (restaurar do dump) |
| **ST-1b.1** | `20260831000100_staff_insert_appointment_core.sql` | `_staff_can_book_for(uuid, boolean)` (posse) + `_staff_insert_appointment(...)` (núcleo comum; **sem `p_exclude_id`**). `security definer`, `search_path=''`, **sem grant** (só o owner chama). | `drop function` de cada |
| **ST-1b.2** | `20260831000200_staff_reschedule_appointment.sql` | `staff_reschedule_appointment(bigint, date, text)` — novo id + cancela o antigo, atômico. `revoke … + grant authenticated`. | `drop function` |
| **ST-1b.3** | `20260831000300_staff_book_encaixe.sql` | `staff_book_encaixe(uuid, jsonb, date, text, bigint[], text, boolean)` — encaixe off-grid sem overbooking; walk-in determinístico + concorrente-seguro. `revoke … + grant authenticated`. | `drop function` |

`git diff a0ac3b7..HEAD` (o branch só tem estes arquivos): as 4 migrations +
`scripts/st1b-lab-matriz.mjs` + `docs/st-1b/RELATORIO.md`.

---

## 2. O que cada migration faz (e onde diverge do legado)

### ST-1b.0 — `backfill_active_duration.sql`
Bloco `do $$` **idempotente por resultado**, roda o preflight em runtime → mesmo
caminho em qualquer ambiente:
- `count(*)` de ativos (`status in ('pendente','confirmado')`) com `duration is null`;
- **0** → `raise notice 'no-op'` + `return` (a migration "aconteceu", fica no histórico);
- dos ativos NULL, os que **não** resolvem 100% pelo catálogo por nome
  (`cardinality(services) <> (select count(*) from services where name = any(services))`):
  se houver algum → `raise exception 'ST-1b.0 abortada: … (ids: %)'` `errcode='P0001'`;
- senão → `update … set duration = (select sum(duration_min) …)` só nos ativos NULL + `raise notice`.

No lab, a 1ª aplicação backfillou os 10 ativos; re-rodar é no-op (G0.1).
**Não** põe `NOT NULL` na coluna (isso é do cutover).

### ST-1b.1 — `_staff_can_book_for` + `_staff_insert_appointment`

**`_staff_can_book_for(p_barber_id, p_allow_vendas)`** — `plpgsql stable security
definer`: `auth.uid()` null → `NOT_AUTH`; `barber_role()` null → `NOT_STAFF`;
`not (p_barber_id = uid ∨ role='admin' ∨ (p_allow_vendas ∧ role='vendas'))` →
`NOT_ALLOWED`. Sem grant.

**`_staff_insert_appointment(p_barber_id, p_day, p_time, p_service_names text[],
p_duration int, p_client_id, p_client_name, p_client_email, p_is_encaixe,
p_status, p_notes, p_grid_aligned)`** — **espelha `_insert_appointment`** (mesma
grade da loja, mesmo `_barber_covers`, mesma checagem de intervalo) com as
diferenças de staff. Ordem:

0. guardas de contrato: `p_status not in ('pendente','confirmado')` → `BAD_STATE`;
   `p_duration is null or <= 0` → `BAD_DURATION`; `cardinality(p_service_names)=0`
   → `SERVICE_INVALID`.
1. `v_cfg := shop_settings`; `v_now := now() at time zone v_cfg.timezone`;
   `v_start := _hhmm_to_min(p_time)` (null → `BAD_SLOT` formato); `v_end := v_start + p_duration`.
2. `p_day < v_now::date` → `PAST_DAY`; `> v_now::date + max_advance_days` → `OUT_OF_WINDOW`.
3. **janela da LOJA** `open_hours -> dow` — não-array (domingo / dia fechado) →
   **`BARBER_OFF`** (a causa é escala). `v_open_min`/`v_close_min`.
4. `v_start < v_open_min or v_end > v_close_min` → `BAD_SLOT` (não cabe no expediente da loja).
5. **se `p_grid_aligned`** (reschedule normal): `(v_start - v_open_min) % slot_min <> 0`
   → `BAD_SLOT`. Encaixe (`p_grid_aligned=false`) **pula** — é o ponto do encaixe.
   A grade é ancorada na **abertura da loja** (igual ao caminho do cliente).
6. `p_day = hoje ∧ v_start <= agora_min` → `PAST_DAY`.
7. barbeiro existe ∧ `is_barber` → senão `BARBER_OFF`.
   `_barber_covers(b.hours, dow, v_start, p_duration)` (hours[dow], ou janela da
   loja se `hours` null; folga = hours[dow] null) → senão `BARBER_OFF`.
8. `pg_advisory_xact_lock(hashtextextended('agenda|'||barber||'|'||dia, 0))`.
9. algum ativo do barbeiro/dia com `duration is null` → **`OVERLAP_UNCHECKED`**
   (nunca compara NULL, nunca fallback — salvaguarda de corrida com escrita legada).
10. sobreposição de intervalo com ativo do mesmo barbeiro
    (`_hhmm_to_min(a.time) < v_end AND v_start < _hhmm_to_min(a.time) + a.duration`)
    → `SLOT_TAKEN`. `is_encaixe` **não** é isento.
11. `v_day_label` montado no servidor; `insert` com `duration` explícita
    (trigger `appointments_fill_duration` não intervém).
12. `exception when exclusion_violation then raise 'SLOT_TAKEN'` — **só** a
    `appointments_no_overlap` (pós-cutover, ausente no lab). Sem `when others`,
    sem `unique_violation`.

**Divergência deliberada vs `_insert_appointment`:** dia fechado da loja →
`BARBER_OFF` (o cliente recebe `BAD_SLOT`). O código é P0001 seguro; a mensagem
("O barbeiro não atende nesse horário") é mais clara para o operador. Registrado
na proposta §3.2.

### ST-1b.2 — `staff_reschedule_appointment(p_id, p_day, p_time)`
O browser manda **só** `p_id, p_day, p_time` (paridade: o modal do legado só tem
data + hora).
1. `v_old := _staff_appt_for_write(p_id, true)` — `NOT_AUTH`/`NOT_STAFF`/`NOT_FOUND`.
   **vendas incluído** (D-1b-1: remarcar preserva o agendamento, não é cancelamento).
2. `v_old.status not in ('pendente','confirmado') ∨ v_old.iniciado_em is not null`
   → `NOT_RESCHEDULABLE` (paridade: `canManage` exige `!em_andamento`).
3. resolve `v_dur`: `v_old.duration` se não-null; senão soma do catálogo **só se
   todos os serviços resolverem** (`count(services) = cardinality`), senão
   `OVERLAP_UNCHECKED` (sem fallback).
4. **cancela o antigo AGORA** (`update … set status='cancelado' where id=p_id`)
   — sai da checagem do núcleo; mover 1 slot não colide consigo mesmo.
5. `v_new_id := _staff_insert_appointment(p_barber_id => v_old.barber_id` (mesmo
   barbeiro — D-1b-2)`, …, p_service_names => v_old.services, p_duration => v_dur,
   …, p_status => v_old.status` (preserva — D-1b-3)`, p_notes => v_old.notes,
   p_grid_aligned => not v_old.is_encaixe)`.
6. se `v_old.client_id` não-null → `notifications ('client', …, 'remarcado', v_new_id, …)`.
   walk-in → sem notif.
7. `return v_new_id`.

**Atomicidade pela transação** (não pela ordem): passo 5 falha → `raise` →
rollback de tudo, inclusive o cancelamento do passo 4 → antigo volta a ativo
(R16). **Sem WhatsApp** (notif in-app é o canal — igual à ST-1a). NÃO muda
barbeiro nem serviços.

### ST-1b.3 — `staff_book_encaixe(p_barber_id, p_client_ref jsonb, p_day, p_time,
p_service_ids bigint[], p_notes default null, p_notify default true)`
1. `_staff_can_book_for(p_barber_id, true)` — `NOT_AUTH`/`NOT_STAFF`/`NOT_ALLOWED`.
2. **forma de `p_client_ref`**: `null ∨ jsonb_typeof <> 'object'` → `CLIENT_INVALID`;
   `mode not in ('account','walkin')` → `CLIENT_INVALID`.
3. resolve o cliente:
   - **account**: `id` validado por **regex** `^[0-9a-f]{8}-…-…-…-[0-9a-f]{12}$`
     **antes** de `::uuid` (nunca `22P02` cru) → senão `CLIENT_INVALID`; tem que
     existir em `public.clients` → senão `CLIENT_INVALID`.
   - **walkin**: `name` btrim 1..80 → senão `WALKIN_INVALID`; `phone` via
     `normalize_phone_br`, `^[0-9]{10,11}$` → senão `WALKIN_INVALID`.
     - **(0) 2 `pg_advisory_xact_lock` em ordem fixa**, namespace `crm|` (≠ do
       lock `agenda|` do núcleo): `'crm|<barber>|tel|<telefone>'` **depois**
       `'crm|<barber>|nom|<lower(nome)>'` — **antes** de qualquer select/insert
       em `crm_clients`.
     - **(a) casa por telefone** (`normalize_phone_br(phone) = v_phone`): card 1 e
       nome bate → reusa; card 1 e nome ≠ → `WALKIN_CONFLICT`; card >1 → `WALKIN_CONFLICT`; vazio → (b).
     - **(b) casa por nome** (`lower(name) = lower(v_name)`): card 0 → **cria**;
       card 1 e `phone is null` → reusa + `update … set phone`; card 1 e phone
       não-null (⇒ ≠) → `WALKIN_CONFLICT`; card >1 → `WALKIN_CONFLICT`
       (estruturalmente impossível — índice único `crm_clients_barber_name_idx`;
       o branch é defesa).
     - `client_id := null; client_name := v_name; client_email := null`.
4. `v_notes := left(regexp_replace(nullif(btrim(coalesce(p_notes,'')),''), '\s{2,}', ' ', 'g'), 500)`.
5. `_validate_services(p_service_ids)` → `v_names`, `v_dur` (propaga `SERVICE_INVALID`).
6. `_staff_insert_appointment(… p_is_encaixe => true, p_status => 'confirmado'`
   (paridade)`, p_notes => v_notes, p_grid_aligned => false)`.
7. `p_notify ∧ v_client_id is not null` → `notifications ('client', v_client_id,
   'encaixe', v_new_id, '<barbeiro> encaixou você: <serviços> — <day_label> às <hora>')`.
   walk-in **ou** `p_notify=false` → sem notif.

`crm_clients` é escrito como owner (bypass RLS `crm_clients_insert_own`) → o
walk-in entra na carteira do **`p_barber_id`**, não na do admin/vendas que criou.

---

## 3. Matriz `84 OK / 0 FAIL` (`scripts/st1b-lab-matriz.mjs`)

Sessões: cliente / barbeiro A (dono, `hours` com quarta de folga) / barbeiro B
(outro) / vendas / admin / **híbrido** (barbeiro **e** cliente). Chamadas via
`psql` (`set local role authenticated` + `request.jwt.claims`) e **corridas
reais** (processos `psql` separados → advisory locks contendem de verdade).

### Gate 0 — `ST-1b.0`
| caso | esperado | resultado |
|---|---|---|
| G0.1 | após aplicar: 0 ativos NULL; os 10 conhecidos = soma do catálogo | OK |
| G0.1 | re-rodar a migration → `notice` no-op | OK |
| G0.1 | ativo NULL resolvível → backfill dirigido (30+15=45) | OK |
| G0.1 | ativo NULL não-resolvível → **aborta** listando o id | OK (`ST-1b.0 abortada: 1 (ids: {…})`) |
| G0.2 | linha **inativa** `duration NULL` **não** entra na sobreposição | OK (encaixe entra) |
| G0.2 | linha **ativa** `duration NULL` → **`OVERLAP_UNCHECKED`**, não insere | OK |

### Reschedule — R1–R20
R1 sucesso (novo id, status preservado, antigo cancelado, herda barbeiro/cliente/
serviços/duração) · R2 slot adjacente da grade → sucesso (cancelar-antes-de-
inserir) · R2b/R13 reschedule normal off-grid → `BAD_SLOT` · R3 slot ocupado →
`SLOT_TAKEN`, antigo intacto · R4 dia de folga → `BARBER_OFF` · R5 ontem →
`PAST_DAY` · R6 `concluido`/`cancelado`/`nao_compareceu` → `NOT_RESCHEDULABLE` ·
R7 em atendimento → `NOT_RESCHEDULABLE` · R8 barbeiro B → `NOT_FOUND` · R9 admin →
sucesso · R10 vendas → sucesso (D-1b-1) · R11 cliente → `NOT_STAFF`; anon →
`permission denied` · R12 híbrido remarca a própria linha-como-cliente →
`NOT_FOUND` · R14 reschedule de encaixe off-grid (13:07→13:22) → sucesso,
`is_encaixe` preservado · R15 corrida → 1 vence / 1 `SLOT_TAKEN` / 1 linha · R16
atomicidade (falha no núcleo → rollback, antigo volta a ativo) · R17 notif
`remarcado` (conta) / 0 (walk-in) · R18 **regressão legado** (`UPDATE
{day,day_label,time}` direto → passa) · R19 ativo NULL c/ serviços resolvíveis →
`v_dur` do catálogo · R20 ativo NULL não-resolvível → `OVERLAP_UNCHECKED`.

### Encaixe — E1–E27 (+E27b)
E1 account off-grid (`is_encaixe=true`, `status='confirmado'`, `client_id` set,
`dur=45`) · E2 walk-in novo (`crm_clients` criado barber=A, `client_id` NULL, 0
notif) · E3 nome na carteira sem telefone → reusa + completa `phone`, não duplica
· E4 telefone na carteira (c/ DDI `55`) + nome bate → reusa · E4b telefone bate /
nome ≠ → `WALKIN_CONFLICT` · E4c 2 linhas mesmo telefone → `WALKIN_CONFLICT` ·
E4d 2º homônimo → barrado pelo índice único (branch é defesa) · E5 dentro de
intervalo ocupado → `SLOT_TAKEN` · E6 90 min sobrepõe à frente → `SLOT_TAKEN` ·
E7 gap real de 30 min → 1 entra, 2º → `SLOT_TAKEN` · E8 dia de folga →
`BARBER_OFF` · E9 antes da abertura / estoura o fechamento → `BAD_SLOT` · E10
serviço vazio/dup/inexistente → `SERVICE_INVALID` · **E11** `p_client_ref` =
string / array / json null / SQL NULL / `{}` / `{mode:'x'}` / `id='abc'` / UUID
inexistente → **`CLIENT_INVALID`** em todos, **nenhum `22P02`** · E12 walk-in
telefone curto/longo / nome vazio/ausente → `WALKIN_INVALID` · E12b `p_notes`
2000 chars → criado, `notes` cortado em 500 · E13 barbeiro A p/ B → `NOT_ALLOWED`
· E14 admin/vendas p/ B → sucesso (D-1b-7) · E15 cliente → `NOT_STAFF`; anon →
`permission denied` · E16 `p_notify=false` → 0 notif · E17 `p_notify=true` → 1
notif `encaixe` `for_role='client'` · E18 ontem → `PAST_DAY` (hoje-passado: SKIP
time-of-day) · E19 corrida 2 encaixes → 1 ok / 1 `SLOT_TAKEN` / 1 linha · E20
`SLOT_TAKEN` → cancela ocupante → entra · E21 **regressão legado** (`INSERT` de
encaixe direto → passa) · E22 cliente-conta que também é barbeiro → permitido ·
E23 (diferido) `appointments_no_overlap` ausente (cutover não aplicado) ·
**E24** corrida walk-in mesmo barber+telefone → 2 appts, **exatamente 1**
`crm_client` · **E25** corrida mesmo nome, telefones ≠ → 1 cria / 1
`WALKIN_CONFLICT` / 1 `crm_client` · **E26** telefone existe c/ nome X, encaixe
c/ nome Y → `WALKIN_CONFLICT` · **E27** walk-in mantém **≥3 advisory locks**
(`crm|tel` + `crm|nom` + `agenda|`) na mesma transação/pid · E27b domingo (loja
fechada) → `BARBER_OFF`.

---

## 4. Checklist `SECURITY DEFINER` — evidências do lab

```
_staff_can_book_for          | secdef=true | search_path="" | exec=(só owner)
_staff_insert_appointment    | secdef=true | search_path="" | exec=(só owner)
staff_reschedule_appointment | secdef=true | search_path="" | exec=authenticated
staff_book_encaixe           | secdef=true | search_path="" | exec=authenticated
```

- `auth.uid()` obrigatório: reschedule via `_staff_appt_for_write` (1ª coisa);
  encaixe via `_staff_can_book_for` (1ª coisa).
- objetos `public.`/`auth.` qualificados; `plpgsql` estático (sem SQL dinâmico).
- **sem cast cru de entrada externa**: `p_client_ref` validado como objeto +
  `mode` allowlist + **UUID por regex antes de `::uuid`** (E11 prova: nenhum `22P02`).
- **duração sempre numérica**: guarda `p_duration > 0`; sobreposição nunca
  compara NULL (`OVERLAP_UNCHECKED`); reschedule resolve da linha antiga/catálogo;
  encaixe de `_validate_services.o_dur`.
- **advisory locks concorrentes**: `agenda|<barber>|<dia>` (núcleo) +
  `crm|<barber>|tel|…` + `crm|<barber>|nom|…` (encaixe walk-in) — ordem global
  fixa `crm|tel → crm|nom → agenda|`, namespaces distintos, todos
  `pg_advisory_xact_lock` (liberados no commit/rollback). E27 confirma ≥3 na
  mesma pid.
- erros: **todos** `errcode='P0001'` (allowlist §8 da proposta).
- guard da ST-H: as RPCs rodam como owner → `current_user='postgres'` → bypass
  (passo 1 do `_appointments_guard_update`); a validação é toda interna.

---

## 5. Paridade × segurança (resumo)

| | legado | ST-1b | classe |
|---|---|---|---|
| remarcar: data + hora, mesmo barbeiro/serviços | ✓ | ✓ | paridade |
| remarcar: revalidação de servidor | ✗ | escala/janela/grade/sobreposição/PAST_DAY | **segurança** |
| remarcar: janela de perda do horário | ✗ | atômico (novo id + cancela antigo) | **segurança** |
| encaixe: horário fora da grade | ✓ | ✓ (`p_grid_aligned=false`) | paridade |
| encaixe: duração digitada no browser | ✓ | **soma do catálogo** | **segurança** |
| encaixe: checagem de sobreposição | ✗ (overbooking silencioso) | `SLOT_TAKEN` — só intervalo livre | **segurança** |
| encaixe: serviços por nome | ✓ | **ids**; nomes/duração do servidor | **segurança** |
| walk-in: dedupe | por nome, client-side, `LIMIT 1` implícito | `normalize_phone_br` + telefone → nome único → `WALKIN_CONFLICT` + 2 advisory locks | **paridade + melhoria** |
| `duration` histórica NULL | fica NULL | **ST-1b.0** backfill dirigido + runtime `OVERLAP_UNCHECKED` | **segurança** |
| WhatsApp no remarcar/encaixe | ✓ | **não** (notif in-app) | **divergência deliberada** |
| `#barberApp` legado | — | ✓ (guard libera `day/time`; INSERT intocado) | **sem regressão** (R18, E21) |

---

## 6. Fronteiras respeitadas

- Só o lab self-hosted. **Produção intocada.** Sem `db push` remoto. Sem merge
  (nem `staff/st-1b` → nada, nem `staff/st-h-gate1` → `master`). Sem cutover.
- `20260829010000_agenda_cutover.sql` continua **não aplicada**.
- `master` do legado **não** recebe as migrations ST-H/ST-1b (decisão do Gabriel,
  mesmo processo da ST-H).
- Próximo passo (fatia separada, sobre `main` do `prime-next`): UI —
  `lib/staff/actions.ts` (`remarcarAtendimento` / `criarEncaixe`, Server Actions
  `requireStaff()` + `.rpc(...)`, nunca `.update()`), `domain/staff.ts`
  (`traduzErroStaffAgenda`), modal de remarcar + painel de encaixe no `/painel`,
  testes/E2E/screenshots/PARIDADE.
