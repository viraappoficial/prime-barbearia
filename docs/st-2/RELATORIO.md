# ST-2 · Atendimento + carrinho + checkout do staff — Relatório do lab

status: **7 migrations escritas e aplicadas SÓ no lab self-hosted. Produção
intocada. Sem `db push`. Sem merge. Cutover `20260829010000` intocado/bloqueado.**
branch: `staff/st-2` (repo `prime-barbearia`), sobre `8c7654b` (ST-1b.5)
data: 2026-08-31 · **hardening de entrada `20260831001600` em 2026-09-01 (pré-merge)**
proposta (aprovada, rev.1): `prime-next@proposta/staff-st2-checkout:docs/investigacoes/10-staff-st2-checkout.md` (`cf083cf`)
UI: `prime-next@fatia/staff-st2-checkout` — Server Actions + modal de fechar conta
depende de: ST-H (`barber_role()`, guard de coluna, RPCs de status) + ST-1b.0–5
(`_lock_agenda`, `_staff_appt_for_write_locked`, `_staff_can_book_for`,
`_validate_services`, `normalize_phone_br`, `_hhmm_to_min`).

**Decisão comercial (Gabriel):** barbeiro pode dar até **15%** de desconto;
vendas até **20%**; admin até **100%**; **acima de 20%** o desconto exige
**motivo obrigatório** (`shop_settings.max_discount_barbeiro/_vendas/_admin` +
`discount_motivo_threshold`, seed 15/20/100/20).

**Resultado da matriz: `103 OK / 0 FAIL`** (`scripts/st2-checkout-matriz.mjs` —
V papel · AB isolamento · C corridas/idempotência atômica (C1a–g) · F1–F22
adulteração/regras · **F23 payload REST malformado (novo, §9)** · A atomicidade ·
EV evidências).

Regressões, todas verdes:

| suíte | resultado |
|---|---|
| `scripts/st2-checkout-matriz.mjs` (ST-2) | **103 OK / 0 FAIL** (era 76; +27 do hardening de entrada) |
| `scripts/agenda-lab-matriz.mjs` | **40 OK / 0 FAIL** |
| `scripts/sth-gate1-matriz.mjs` (ST-H) | **158 OK / 0 FAIL** |
| `scripts/st1b-lab-matriz.mjs` (ST-1b) | **85 OK / 0 FAIL** — ⚠️ `E18 encaixe hoje-passado` é *flake de relógio* do harness ST-1b: FALHA só quando o relógio do lab está entre ~09:31 e 10:00 num dia útil (o slot "passado" = `agora−60min` cai antes da abertura 09:00 → `staff_book_encaixe` devolve `BAD_SLOT` em vez de `PAST_DAY`). NÃO tem relação com a ST-2 (o harness ST-1b não carrega migration ST-2). Verde fora dessa janela. |
| `scripts/st1b4-concurrency-matriz.mjs` | **28 OK / 0 FAIL** |
| `scripts/st1b5-agenda-lock-matriz.mjs` | **26 OK / 0 FAIL** |
| `prime-next` `check` (168) + `build` | verdes |
| `prime-next` `test:staff-st2-lab` (REST, +18 casos malformados) · `shots:staff-st2` (E2E) | verdes |

Lab termina com **37 appointments / 64 sales**, sem objeto/dado de teste desta
tarefa. As 6 funções/RPCs novas + a sequence + as colunas aditivas + os 3 helpers
de guarda de entrada da ST-2.7 ficam **aplicados** (rollout lab-first, igual à
ST-H/ST-1b). `sales_nota_seq` fica **avançada** (ids "queimados" pelas iterações
de teste — inofensivo; `nota_id` não precisa ser contíguo).

---

## 1. Numeração

Última migration real aplicada: `20260831000500` (ST-1b.5). Data corrente
2026-08-31 → prefixo **`20260831`**, faixa `001000+` (deixa `000600–000999`
livre para eventuais ST-1b.x). Ordena depois de toda a ST-1b; **não** depende
do cutover (`20260829010000`) e **não** o toca.

| # | arquivo | o quê | rollback |
|---|---|---|---|
| **ST-2.1** | `20260831001000_sales_nota_sequence.sql` | `create sequence if not exists public.sales_nota_seq`; `do $$` que ancora `setval(max(nota_id)+1, false)` **só se atrás** (idempotente, nunca regride); `revoke all` de toda role externa. **GATE DE PRODUÇÃO** documentado no cabeçalho (não conviver com o contador `localStorage` do legado). | `drop sequence public.sales_nota_seq;` |
| **ST-2.2** | `20260831001100_st2_schema.sql` | aditivas nullable/com default: `sales.{unit_price, discount, discount_motivo}`, `appointments.discount_motivo`, `shop_settings.{max_discount_barbeiro=15, max_discount_vendas=20, max_discount_admin=100, discount_motivo_threshold=20}` + CHECK `0..100`. | `alter table … drop column if exists …` (cada uma) + `drop constraint shop_settings_discount_pct_chk` |
| **ST-2.3** | `20260831001200_checkout_helpers.sql` | `_validate_services_priced(bigint[])` **nova e separada** (não toca a v1); `_apply_coupon(text, bigint[])` (math + escopo server-side; `valor_fixo` clampado a `[0,total]`); `_resolve_discount(text, jsonb, numeric)` (teto por papel + motivo > threshold; cupom exento; acréscimo bloqueado); `_lock_checkout(uuid)` (advisory `checkout|<key>`); `_staff_insert_completed_walkin_appt(...)` (atendimento concluído de balcão-com-conta — **não** usa o núcleo genérico); **`decrement_product_stock` REESCRITO** (`search_path=''`, P0001 `BAD_QTY`/`OUT_OF_STOCK`, `barber_role() is not null` → `NOT_STAFF`; `revoke anon`, **mantém `authenticated`**); `validate_coupon` `revoke anon`. Helpers: `revoke` de todos, sem grant. | `drop function` de cada helper novo; `create or replace` de `decrement_product_stock` / `validate_coupon` de volta ao baseline; `grant execute … to anon` de volta |
| **ST-2.4** | `20260831001300_staff_cart_rpcs.sql` | `_staff_cart_appt(bigint)` (appt travado + em andamento → `BAD_STATE`); `staff_cart_add_item` / `staff_cart_set_qty` (valida `stock`, posse, estado); `staff_cart_set_services(bigint, bigint[], jsonb)` (**único escritor** de `appointments.services/discount_price/coupon_code/discount_motivo` pelo app); `staff_checkout_get(bigint)` (estado consolidado da tela). Policy nova `cart_items_admin_all` (**`EXISTS` inline**, não `barber_role()` — ver §5). RPCs públicas `revoke … + grant authenticated`. | `drop function` de cada; `drop policy cart_items_admin_all on public.cart_items` |
| **ST-2.5** | `20260831001400_staff_checkout.sql` | tabela `staff_checkout_log` (PK `idempotency_key`, RLS `select own/admin` via `EXISTS` inline, **sem** INSERT/UPDATE/DELETE externo); `_staff_resolve_client_ref(uuid, jsonb)` (contrato ST-1b.3 — account por regex, walk-in concorrente-seguro com locks `crm|`); **`staff_checkout(...)`** — a transação (§3). `revoke … + grant authenticated`. | `drop function public.staff_checkout(bigint,uuid,jsonb,bigint[],jsonb,jsonb,jsonb,text,uuid);` `drop function public._staff_resolve_client_ref(uuid, jsonb);` `drop table public.staff_checkout_log;` |
| **ST-2.6** | `20260831001500_checkout_grants_hygiene.sql` | `revoke truncate, trigger, references` de `anon, authenticated` em `sales, sale_payments, cart_items, coupons, products, services, taxas_maquininha, cash_*, bank_accounts, fiado_*` (mesmo H-F da ST-H.5). **Mantém** INSERT/UPDATE/DELETE/SELECT até o cutover — a RLS filtra e o `#barberApp` legado ainda escreve. | `grant truncate, trigger, references on … to anon, authenticated;` |
| **ST-2.7** | `20260831001600_checkout_input_guards.sql` | **hardening de entrada (pré-merge, §9).** `_checkout_num` / `_checkout_int` / `_checkout_date` (helpers puros, owner-only, `search_path=''`) — validam tipo/forma do JSON **antes** de todo cast vindo do cliente. `create or replace` de **`_resolve_discount`** (`price`/`pct` via `_checkout_num`; payload não-objeto → `DISCOUNT_NOT_ALLOWED`) e **`staff_checkout`** (container `p_products`/`p_payments` não-array → `BAD_INPUT`; `product_id`/`qty` via `_checkout_int`; `value` via `_checkout_num` nos 2 laços; `due_date` via `_checkout_date`; `parcelas` via `_checkout_int`). **Não** altera as 6 migrations ST-2 já aplicadas. | `create or replace` de `_resolve_discount` (corpo de `..001200`) e `staff_checkout` (corpo de `..001400`); `drop function` dos 3 helpers `_checkout_*` |

`git diff 8c7654b..HEAD`: as 7 migrations + `scripts/st2-checkout-matriz.mjs` +
`docs/st-2/RELATORIO.md`. (A troca de `staff_write_row_lock`/`agenda_lock_protocol`
na lista `FILES` do matriz é comentário — ver §6.) Diff só desta fatia
(`6fe5ef3..HEAD`): `supabase/migrations/20260831001600_checkout_input_guards.sql`
(novo) + F23 em `scripts/st2-checkout-matriz.mjs` + este relatório; no
`prime-next`: +18 casos malformados em `scripts/staff-st2-lab-test.mjs`.

---

## 2. Contrato do checkout (proposta §4.1 / D-ST2-16)

`staff_checkout` tem **dois caminhos mutuamente exclusivos** por `p_appt_id`:

| | **agenda** (`p_appt_id` não-null) | **balcão** (`p_appt_id` null) |
|---|---|---|
| serviços + desconto | **só** o estado persistido em `appointments` (por `staff_cart_set_services`). `p_service_ids`/`p_discount` não-nulos → `SERVICE_/DISCOUNT_SOURCE_CONFLICT` | `p_service_ids` + `p_discount` são os parâmetros |
| produtos | **só** `cart_items` do appt. `p_products` não-vazio → `PRODUCT_SOURCE_CONFLICT` | **só** `p_products` `[{product_id, qty}]` |
| cliente | de `appointments` | `p_client_ref` (contrato ST-1b.3) |
| barbeiro | dono do appt; `p_barber_id` rejeitado | `p_barber_id` (vendas/admin validados) |

**Não há `p_date`/`p_time`** — data/hora da venda são `now() at time zone
shop_settings.timezone` (data de **finalização**). Período fechado usa essa data.

Servidor resolve: preço de serviço/produto (catálogo por `id`), custo,
categoria, total, desconto (teto por papel), **`nota_id` (`nextval`)**,
`client_name` da venda, `status`, troco. `p_payments[i].value` é **proposta de
valor recebido**; excedente só coberto por linhas `dinheiro`; o servidor grava
em `sale_payments` **só o valor liquidado** → `Σ sale_payments.value = total`
exato.

---

## 3. `staff_checkout` — a transação (resumo)

```
0. p_idempotency_key não-null (uuid)        senão BAD_INPUT
1. auth.uid() / barber_role()               → NOT_AUTH / NOT_STAFF ; v_fp := md5(inputs)
2. perform _lock_checkout(key)              -- advisory 'checkout|<key>', ANTES de tudo
3. select … from staff_checkout_log where key
     achou: v_fp <> log.fingerprint         ⇒ IDEMPOTENCY_MISMATCH
            reautoriza (actor | admin/vendas | barbeiro dono) senão NOT_ALLOWED
            return log.receipt  (status: replayed)
4. caminho AGENDA:  *_SOURCE_CONFLICT se params ; _lock_agenda(barber, day) ;
                    v_appt := _staff_appt_for_write_locked(p_id, true)  -- FOR UPDATE
                    status='concluido' ⇒ ALREADY_CHECKED_OUT ;
                    status<>'confirmado' ou iniciado_em null ⇒ BAD_STATE ;
                    serviço/desconto de v_appt ; produtos de cart_items (FOR UPDATE)
   caminho BALCÃO:  _staff_can_book_for(barber, true) ; _staff_resolve_client_ref ;
                    _validate_services_priced + _resolve_discount ; produtos de p_products ;
                    se CONTA + serviço → _lock_agenda + _staff_insert_completed_walkin_appt
5. total := valor_servico + Σ produtos                (servidor)
6. v_date/v_time := now() at time zone tz ;  cash_closures cobre v_date ⇒ PERIOD_CLOSED
7. pagamentos: method ∈ enum, value>0 senão BAD_PAYMENT_METHOD ; a_prazo due_date futura
   senão FIADO_DUE_REQUIRED ; Σ recebido ≥ total senão PAYMENT_MISMATCH ;
   excedente só em dinheiro senão PAYMENT_MISMATCH ; liquida o troco das linhas de dinheiro
8. nota_id := nextval('public.sales_nota_seq')
9. INSERT sales (1 linha serviço + N linhas produto ; unit_price/discount/discount_motivo)
10. INSERT sale_payments (liquidado — Σ = total) ; INSERT fiado_charges (a_prazo)
11. UPDATE products SET stock = stock - qty WHERE stock >= qty  → 0 linhas ⇒ OUT_OF_STOCK
12. (agenda) UPDATE appointments status='concluido' ; DELETE cart_items
13. INSERT notifications (client, 'concluido')  se v_client_id
14. INSERT staff_checkout_log (fingerprint, receipt) ; return receipt
```

**Atomicidade:** falha em **2–14** → `raise` → `ROLLBACK` completo (inclui o log,
o appt retroativo, o `crm_clients` do walk-in, o advisory liberado). A A-series
injeta falha em cada passo e verifica **estado zero**. `sales_nota_seq` avança
(sequence não faz rollback — documentado).

**Ordem de locks (sem ciclo):** `checkout|<key>` → `agenda|barber|day` →
`appointments` FOR UPDATE → `cart_items` FOR UPDATE → `products` (no `UPDATE …
WHERE stock >= qty`). Consistente com o protocolo canônico da ST-1b.5. A C3/C4
(checkout ‖ reschedule / cancel) provam **0 `40P01`**.

---

## 4. Matriz `76 OK / 0 FAIL`

### V — papel
V1 barbeiro finaliza o próprio (svc + produto, split dinheiro+crédito) → 2 linhas
`sales` mesmo `nota_id`, `Σ sale_payments = total`, appt `concluido`, carrinho
limpo, estoque −qty, notif ao cliente, `staff_checkout_log` gravado · V2 barbeiro
B → `NOT_FOUND` (nada gravado) · V3 vendas "em nome de" A → `sales.barber_id = A`
· V4 admin → ok · V5 cliente → `NOT_STAFF` · V6 anon → `permission denied` · V7
híbrido finaliza a própria linha-como-cliente → `NOT_FOUND` · V8 balcão walk-in
só produtos → `sales` sem `appointment_id`, `crm_clients` criado, **sem**
retroativo · V9 balcão conta + serviço → retroativo `concluido` na transação.

### AB — isolamento
barbeiro B não lê `staff_checkout_get` de appt de A (`NOT_FOUND`); vendas/admin
leem; cliente não lê `sales` (RLS, 0 linhas).

### C — corridas (idempotência ATÔMICA)
C1a agenda mesma key (6×) → mesmo `nota_id`, 1 venda, ambos recibo · **C1b BALCÃO
mesma key (6×)** → idem (o `_lock_checkout` serializa antes de qualquer escrita)
· C1c N=5 mesma key → 5 ok, 1 venda · C1d mesma key + inputs diferentes →
`IDEMPOTENCY_MISMATCH` · C1e replay por barbeiro B → `NOT_ALLOWED` · C1f replay
por admin → `replayed` · C1g falha (`OUT_OF_STOCK`) → rollback **sem log órfão**;
retry mesma key → ok, venda nova · C2 mesmo appt keys distintas (6×) → 1 vence, 1
`ALREADY_CHECKED_OUT`, 1 venda · C3 checkout ‖ `staff_reschedule` (6×) → 0
`40P01` · C4 checkout ‖ `staff_cancel` (6×) → 0 `40P01` · C5 2 balcões → 2
`nota_id` distintos · C6 2 vendas do último item (6×) → 1 vende, 1
`OUT_OF_STOCK`, stock 0 · C7 `pg_locks` confirma o advisory `checkout|<key>`.

### F — adulteração / regras (F1–F22)
F1 pagamento menor → `PAYMENT_MISMATCH` · F2 excedente em crédito → `PAYMENT_MISMATCH`
· F3 excedente em dinheiro → ok, `Σ sale_payments = total`, recibo com troco · F4
**barbeiro 16% → `DISCOUNT_NOT_ALLOWED`; vendas 21% → idem; admin 25% sem motivo
→ `DISCOUNT_MOTIVO_REQUIRED`; admin 25% com motivo → ok (`discount_price 33.75`,
motivo persistido); barbeiro 10% → ok (`40.50`)** · F4b acréscimo → bloqueado ·
F5 cupom inexistente → `COUPON_INVALID` · F6 cupom com escopo + 2 serviços →
`COUPON_NOT_APPLICABLE`; cupom `PRIMEIROCORTE` em Corte Social → `24.99` sem
motivo (cupom exento) · F7 serviço inválido → `SERVICE_INVALID` · F8 produto
inexistente / `qty ≤ 0` → `PRODUCT_INVALID` / `BAD_QTY` · F9 `qty > stock` →
`OUT_OF_STOCK` · F10 appt não iniciado → `BAD_STATE` · F11 appt concluído →
`ALREADY_CHECKED_OUT` · F12 método fora do enum → `BAD_PAYMENT_METHOD` · F13
`a_prazo` sem/venc≤hoje → `FIADO_DUE_REQUIRED`; venc futura → ok + `fiado_charges`
`aberto` · **F14** caminho agenda + `p_service_ids`/`p_discount`/`p_products` →
`*_SOURCE_CONFLICT` · **F15/F16** finaliza hoje em `cash_closures` fechado →
`PERIOD_CLOSED`; reaberto → ok, `sales.date = hoje` · F17 params forjados
ignorados (servidor resolve) · **F18** `decrement_product_stock` por anon →
`permission denied`; **F19** por cliente logado → `NOT_STAFF`; **F20** por
barbeiro logado (legado) → **ok** · F21 `validate_coupon` por anon →
`permission denied`; por cliente logado → ok · F22 sem `p_idempotency_key` →
`BAD_INPUT`.

### A — atomicidade
A1 produto sem estoque no meio → `OUT_OF_STOCK`; **0** em `sales`/`sale_payments`/
`staff_checkout_log`, estoque intacto, appt intacto, `cart_items` intacto;
`sales_nota_seq` avançou (documentado) · A2 balcão conta+serviço com pagamento
insuficiente → retroativo **não** criado · A3 walk-in + pagamento insuficiente →
`crm_clients` **não** criado.

### EV
`staff_checkout` / `staff_checkout_get` / `staff_cart_*` — `secdef`,
`search_path=""`, `grant authenticated`. `_validate_services_priced` /
`_apply_coupon` / `_resolve_discount` / `_lock_checkout` /
`_staff_resolve_client_ref` / `_staff_insert_completed_walkin_appt` — `secdef`,
`search_path=""`, **só owner**. `decrement_product_stock` — `search_path=""`,
`grant authenticated` (revoke anon). `validate_coupon` — sem `anon`.
`sales_nota_seq` — sem `USAGE` externo. Higiene: sem `TRUNCATE/TRIGGER/REFERENCES`
para `anon`/`authenticated` nas tabelas de venda.

---

## 5. Decisões de implementação

- **Policies novas usam `EXISTS (… role='admin')` inline, não `barber_role()`.**
  `cart_items_admin_all` e `staff_checkout_log_select_own` seguem o padrão de
  `sales`/`products`/`cash_*` (que já são inline). Motivo técnico: uma policy que
  depende de `barber_role()` **bloqueia** o `drop function barber_role()` do
  ciclo de rollback isolado da `sth-gate1-matriz` (as policies da ST-H.2 são
  revertidas **antes** do drop; uma policy nova da ST-2 não seria). Com o inline,
  a `sth-gate1-matriz` volta a **158/0**.
- **`_validate_services` (v1) intocada** — `_validate_services_priced` é função
  nova e separada (v1 é usada por `book_appointment` / `_staff_insert_appointment`
  da agenda; regressão garantida por `agenda-lab-matriz` 40/0).
- **`decrement_product_stock` — estratégia única (D-ST2-10):** reescrito com
  `barber_role()` + revoke `anon`, **mantém `authenticated`** → o `#barberApp`
  legado (barbeiro logado) segue chamando. Versão owner-only entra no cutover.
  **Risco residual de *insider staff* até o cutover** — registrado.
- **`_staff_insert_completed_walkin_appt` (D-ST2-17):** o núcleo genérico
  `_staff_insert_appointment` rejeita `status='concluido'` (`BAD_STATE`). Helper
  dedicado, owner-only, na transação do checkout. Data/hora do servidor no fuso
  da loja; sem regra de marcação (grade / janela / `_barber_covers` /
  sobreposição) — é registro do que ocorreu, não agendamento.
- **`nota_id` — GATE DE PRODUÇÃO (D-ST2-18):** `setval(max+1)` **não** faz o
  contador `localStorage` do legado e a sequence conviverem. **No lab** só a ST-2
  escreve venda → a sequence é a única fonte. **Em produção** a ST-2 de checkout
  só entra depois que o `baPgtoConfirmar` legado cortar pra RPC / usar um
  alocador comum / cutover. **Não afirmar "convivência segura".** Preflight de
  colisão histórica (grupos incompatíveis por `nota_id`) na proposta §4.8.
- **Sem `revalidatePath` nas Server Actions do checkout** — o componente
  gerencia o estado pelo retorno das RPCs; revalidar ao concluir o appt
  desmontaria o modal antes do recibo. `router.refresh()` acontece só ao fechar
  o recibo.

---

## 6. Ordem de execução das matrizes (fragilidade documentada)

O ciclo de rollback isolado da `sth-gate1-matriz` reverte a ST-H e, com ela, o
lock das RPCs de status da ST-1b.4 (recria as versões originais de `staff_accept`
etc. via re-apply da ST-H.4). Cada matriz **re-aplica a própria camada** no
início — então a ordem canônica é:

```
agenda → sth-gate1 → st1b → st1b4 → st1b5 → st2
```

`st2-checkout-matriz.mjs` re-aplica **ST-1b.4 + ST-1b.5 + ST-2.1–6** no início
(a `FILES`), de modo que **rodá-la por último restaura a consistência total**
do lab (RPCs de status travadas, protocolo canônico, checkout). Verificado:
após a suíte completa, `staff_accept` usa `_staff_appt_for_write_locked`,
`_insert_appointment` usa `_lock_agenda`, guard e trigger presentes, lab 37/64.

---

## 7. Rollback (ordem reversa; helpers/tabelas por último)

```sql
-- ST-2.6
grant truncate, trigger, references on
  public.sales, public.sale_payments, public.cart_items, public.coupons,
  public.products, public.services, public.taxas_maquininha,
  public.cash_closures, public.cash_sangrias, public.cash_supplies,
  public.bank_accounts, public.fiado_charges, public.fiado_invoices
  to anon, authenticated;

-- ST-2.5
drop function public.staff_checkout(bigint,uuid,jsonb,bigint[],jsonb,jsonb,jsonb,text,uuid);
drop function public._staff_resolve_client_ref(uuid, jsonb);
drop table public.staff_checkout_log;

-- ST-2.4
drop function public.staff_checkout_get(bigint);
drop function public.staff_cart_set_services(bigint, bigint[], jsonb);
drop function public.staff_cart_set_qty(bigint, bigint, int);
drop function public.staff_cart_add_item(bigint, bigint, int);
drop function public._staff_cart_appt(bigint);
drop policy cart_items_admin_all on public.cart_items;

-- ST-2.3
drop function public._staff_insert_completed_walkin_appt(uuid,uuid,text,text,text[],int,text);
drop function public._lock_checkout(uuid);
drop function public._resolve_discount(text, jsonb, numeric);
drop function public._apply_coupon(text, bigint[]);
drop function public._validate_services_priced(bigint[]);
-- decrement_product_stock / validate_coupon: CREATE OR REPLACE de volta ao
-- baseline (search_path='public', erros de texto cru) + grants originais:
grant execute on function public.decrement_product_stock(bigint, integer) to anon, service_role;
grant execute on function public.validate_coupon(text) to anon;

-- ST-2.2
alter table public.sales         drop column if exists unit_price;
alter table public.sales         drop column if exists discount;
alter table public.sales         drop column if exists discount_motivo;
alter table public.appointments  drop column if exists discount_motivo;
alter table public.shop_settings drop constraint if exists shop_settings_discount_pct_chk;
alter table public.shop_settings drop column if exists max_discount_barbeiro;
alter table public.shop_settings drop column if exists max_discount_vendas;
alter table public.shop_settings drop column if exists max_discount_admin;
alter table public.shop_settings drop column if exists discount_motivo_threshold;

-- ST-2.1
drop sequence public.sales_nota_seq;
```

Nenhuma linha de `sales`/`sale_payments`/`fiado_charges` gravada por
`staff_checkout` no lab (dados de teste limpos). Rollback não perde histórico
real — as colunas aditivas eram nullable e o legado nunca as escreveu.

---

## 8. Fronteiras respeitadas

- Só o lab self-hosted. **Produção intocada.** Sem `db push` remoto. Sem merge.
- `20260829010000_agenda_cutover.sql` continua **não aplicada**.
- `master` do legado **não** recebe as migrations ST-H/ST-1b/ST-2.
- `.env`/segredos/artefatos fora dos commits. Os 6 arquivos staged
  pré-existentes do repo (`.claude/skills/...`, `CLAUDE.md`, `Flayers/*`,
  `package-lock.json`) **não** entram no commit (pathspec).
- Hardening pendente da ST-1b.5 §6 (`cancel_appointment` do cliente sem
  `FOR UPDATE`) **não** foi tocado nesta fatia.

---

## 9. ST-2.7 — hardening de entrada do checkout (pré-merge, 2026-09-01)

### Achado

Payload REST **malformado** vazava SQLSTATE cru (`22P02` invalid_text_representation
/ `22007`–`22008` invalid/out-of-range datetime) em vez de `P0001` + código da
allow-list, porque três funções faziam cast direto de valor vindo do cliente:

| função | cast cru | payload que quebrava |
|---|---|---|
| `_resolve_discount` | `(p_discount ->> 'price')::numeric`, `(p_discount ->> 'pct')::numeric` | `price`/`pct` = `"abc"`, `{…}`, `[…]` → **`22P02` cru**. `"NaN"`/`"Infinity"` só eram barrados **por acidente** (`NaN > teto`, e `NaN` compara "maior" no `numeric` do PG). |
| `staff_checkout` (produtos, balcão) | `(v_el ->> 'product_id')::bigint`, `(v_el ->> 'qty')::int` | `product_id`/`qty` = texto/objeto → **`22P02` cru**. |
| `staff_checkout` (pagamentos) | `(v_el ->> 'value')::numeric`, `(v_el ->> 'due_date')::date`, `(v_el ->> 'parcelas')::int` | `value` = `"abc"` → **`22P02`**; `value` = `"NaN"` em `dinheiro` → passava e **gravava `sale_payments.value = NaN`**; `due_date` = `"2026-13-40"` → **`22007`/`22008` cru**; `parcelas` = `"abc"` → **`22P02`**. |

Além disso `p_products` **não-null e não-array** (`{…}`, `"x"`, `5`) era
**silenciosamente ignorado** em vez de falhar.

### Correção

`20260831001600_checkout_input_guards.sql` — **incremental**, não altera as 6
migrations ST-2 já aplicadas; `create or replace` só nas 2 funções afetadas +
3 helpers puros novos.

- **`_checkout_num(jsonb, code) → numeric`** — aceita **número JSON** ou
  **string decimal limpa** (`^-?\d+(\.\d+)?$`); rejeita ausente/null, objeto,
  array, boolean, `"NaN"`, `"Infinity"`, `"1e5"`, e (defensivo) `NaN`/`±Infinity`
  já materializados. Erro → `raise using errcode='P0001'` com o código recebido.
- **`_checkout_int(jsonb, code, min, max) → bigint`** — inteiro na faixa;
  rejeita não-inteiro (`1.5`, `"1.5"`), texto, objeto, fora de faixa. Cobre o
  antigo `qty <= 0` (min = 1).
- **`_checkout_date(jsonb, code) → date`** — string ISO estrita `YYYY-MM-DD`;
  o bloco `exception` traduz o `22007`/`22008` de data fora de faixa.
- **`_resolve_discount`** — corpo idêntico ao de `..001200` exceto: (1)
  `p_discount` não-objeto quando não-null → `DISCOUNT_NOT_ALLOWED`; (2)
  `price`/`pct` via `_checkout_num(…, 'DISCOUNT_NOT_ALLOWED')`; (3) `service_ids`
  do modo cupom só é iterado se for array JSON.
- **`staff_checkout`** — corpo idêntico ao de `..001400` exceto: (A) `p_products`
  / `p_payments` não-null e não-array → `BAD_INPUT` **antes de qualquer lock**;
  (B) item de `p_products` precisa ser objeto → `BAD_INPUT`; `product_id` via
  `_checkout_int(…, 'PRODUCT_INVALID', 1, …)`; `qty` via `_checkout_int(…,
  'BAD_QTY', 1, …)`; (C) item de `p_payments` precisa ser objeto →
  `BAD_PAYMENT_METHOD`; `value` via `_checkout_num(…, 'BAD_PAYMENT_METHOD')` nos
  **dois** laços; `due_date` via `_checkout_date(…, 'FIADO_DUE_REQUIRED')`;
  `parcelas` via `_checkout_int(…, 'BAD_PAYMENT_METHOD', 1, 99)`; (D) balcão sem
  serviço com `p_discount` não-objeto → `DISCOUNT_NOT_ALLOWED`.

Assinatura, retorno e grants das 2 RPCs **inalterados** (`create or replace`
preserva os grants; re-assertados por idempotência). Todos os códigos usados
(`BAD_INPUT`, `BAD_QTY`, `PRODUCT_INVALID`, `BAD_PAYMENT_METHOD`,
`FIADO_DUE_REQUIRED`, `DISCOUNT_NOT_ALLOWED`) já estão na allow-list de
`traduzErroStaffVenda` (`prime-next/domain/staff.ts`) → **UI intocada**.

### Contratos válidos preservados

A UI (`descontoParaRpc` / `finalizarCheckout`) manda `price`/`pct`/`value`/
`parcelas` como **número JSON** e `due_date` como **string ISO** — todos
aceitos sem mudança (provado por F23h/F23z na matriz e pelo caso "contrato
válido" no `test:staff-st2-lab`, além das regressões V/F1–F22/E2E verdes).

### Fora do alcance (registrado)

Parâmetros **escalares/array tipados** da assinatura (`p_service_ids bigint[]`,
`p_idempotency_key uuid`): um valor malformado é recusado pelo **PostgREST na
coerção de argumento, ANTES do corpo rodar** (HTTP 400, sem escrita parcial,
sem lock). Blindá-los exigiria trocar o contrato (receber `jsonb` e fazer parse
interno) — mudança de escopo, fora desta fatia. Não é risco de venda parcial.

### Matriz

`scripts/st2-checkout-matriz.mjs` ganhou o bloco **F23** (23 asserções):
`price`/`pct` texto/objeto/array/boolean/`"NaN"`/`"Infinity"`; `product_id`/`qty`
texto/objeto/`1.5`/ausente; item não-objeto; container não-array; `value`
texto/`"NaN"`/objeto; `p_payments` objeto; `due_date` não-ISO/`"2026-13-40"`/objeto;
`parcelas` `"abc"`/`2.5` — **cada caso: `!ok` + código da allow-list + ZERO
`22P0x`/`2200x`/texto cru**, mais 2 casos de contrato válido. Total **103 OK / 0
FAIL** (era 76). `prime-next/scripts/staff-st2-lab-test.mjs` ganhou **18 casos**
pelo caminho REST provando `{ code:'P0001', message ∈ allow-list }` em todos.

### E18 (ST-1b) — flake de relógio, sem relação

`st1b-lab-matriz` `E18 encaixe hoje-passado` FALHA **apenas** quando o relógio do
lab está entre ~09:31 e 10:00 num dia útil: o harness monta um slot "passado" =
`agora − 60min`, que nessa janela cai **antes** da abertura da loja (09:00), e
`staff_book_encaixe` devolve `BAD_SLOT` (fora do expediente) em vez de `PAST_DAY`.
O harness ST-1b **não carrega nenhuma migration ST-2** e não referencia
`staff_checkout`/`_resolve_discount`/`_checkout_*` — a falha independe desta
fatia. Verde fora dessa janela (85/0).
