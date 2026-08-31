/**
 * ST-2 · matriz de checkout (atendimento + carrinho + venda) contra o LAB
 * (localhost:8100 / supabase-db).
 *
 * Cobre as 6 migrations `20260831001000..1500`:
 *   sales_nota_seq · schema (snapshot + tetos de desconto) · helpers
 *   (_validate_services_priced, _apply_coupon, _resolve_discount, _lock_checkout,
 *   _staff_insert_completed_walkin_appt, decrement_product_stock reescrito) ·
 *   staff_cart_* · staff_checkout (+ staff_checkout_log) · higiene de grants.
 *
 * - V : matriz por papel (barbeiro / vendas / admin / cliente / anon / híbrido)
 * - AB: isolamento A/B
 * - C : corridas reais — idempotência ATÔMICA (C1a–g), ALREADY_CHECKED_OUT,
 *       checkout ‖ reschedule/cancel, estoque do último item, 0 40P01
 * - F : adulteração / regras (F1–F22) incl. tetos de desconto por papel
 * - A : atomicidade (falha em cada passo → estado zero)
 * - EV: evidências (secdef / search_path / grants / sequence)
 *
 * Aplica ST-2.1–6 (idempotente) e deixa APLICADAS. Semeia usuários/produtos/
 * agendamentos de teste e LIMPA no fim — lab volta a 37 appts / 64 sales.
 * Nunca toca produção / db push / cutover.
 *
 * Uso: node scripts/st2-checkout-matriz.mjs
 */
import { readFileSync } from 'node:fs'
import { execFileSync, spawn } from 'node:child_process'
import { randomUUID } from 'node:crypto'

const LAB = 'http://localhost:8100'
const MIG = new URL('../supabase/migrations/', import.meta.url)
// ST-1b.4/.5 recriam as 6 RPCs de escrita de staff (protocolo de lock) das quais
// a ST-2 depende — re-aplicadas aqui para que rodar esta matriz por último
// restaure a consistência total mesmo depois do ciclo de rollback isolado da
// sth-gate1-matriz (que reverte a ST-H e, com ela, o lock das RPCs de status).
const FILES = [
  '20260831000400_staff_write_row_lock.sql',
  '20260831000500_agenda_lock_protocol.sql',
  '20260831001000_sales_nota_sequence.sql',
  '20260831001100_st2_schema.sql',
  '20260831001200_checkout_helpers.sql',
  '20260831001300_staff_cart_rpcs.sql',
  '20260831001400_staff_checkout.sql',
  '20260831001500_checkout_grants_hygiene.sql',
]
const AK = readFileSync('/home/gabrielparcel/projetos/prime-next/.env.local', 'utf8')
  .split('\n').find((l) => l.startsWith('NEXT_PUBLIC_SUPABASE_ANON_KEY=')).split('=')[1].trim()
const anonH = { apikey: AK, 'Content-Type': 'application/json' }

const PSQL = ['exec', '-i', 'supabase-db', 'psql', '-U', 'postgres', '-d', 'postgres', '-qtAX', '-v', 'ON_ERROR_STOP=1']
const psql = (s) => execFileSync('docker', PSQL, { input: s, encoding: 'utf8' }).trim()
const psqlNotice = (sql) => execFileSync('bash', ['-c',
  'docker exec -i supabase-db psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qX 2>&1'], { input: sql, encoding: 'utf8' })
const psqlFile = (p) => psqlNotice(readFileSync(p, 'utf8'))
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const reloadPgrst = async () => { psql("notify pgrst, 'reload schema';"); await sleep(500) }

const wrapAs = (uid, sql) => {
  const claims = uid ? `{"sub":"${uid}","role":"authenticated"}` : `{"role":"anon"}`
  return `begin;\nset local role ${uid ? 'authenticated' : 'anon'};\nset local request.jwt.claims to '${claims}';\n${sql}\ncommit;`
}
const callAs = (uid, sql) => execFileSync('docker', PSQL, { input: wrapAs(uid, sql), encoding: 'utf8' }).trim()
const tryCallAs = (uid, sql) => {
  try { return { ok: true, out: callAs(uid, sql) } }
  catch (e) { return { ok: false, err: ((e.stderr || '') + (e.stdout || '') || e.message).toString() } }
}
const callAsP = (uid, sql) => new Promise((resolve) => {
  const p = spawn('docker', PSQL)
  let out = '', err = ''
  p.stdout.on('data', (d) => { out += d }); p.stderr.on('data', (d) => { err += d })
  p.on('close', (code) => resolve(code === 0 ? { ok: true, out: out.trim() } : { ok: false, err: (err + out).toString() }))
  p.stdin.write(wrapAs(uid, sql)); p.stdin.end()
})

const rid = Math.random().toString(36).slice(2, 7)
const PFX = `st2-${rid}`
let pass = 0, fail = 0
const ok = (n, c, extra = '') => {
  c ? pass++ : fail++
  console.log(`  ${c ? 'OK  ' : 'FAIL'} ${n}${extra ? `  — ${String(extra).replace(/\s+/g, ' ').slice(0, 180)}` : ''}`)
}
const ERR = (s) => (String(s).split('\n').find((l) => /ERROR|DETAIL/.test(l)) || String(s).slice(0, 120)).trim()
const CODES = /NOT_AUTH|NOT_STAFF|NOT_FOUND|NOT_ALLOWED|BAD_INPUT|BAD_STATE|ALREADY_CHECKED_OUT|IDEMPOTENCY_MISMATCH|SERVICE_INVALID|SERVICE_SOURCE_CONFLICT|DISCOUNT_SOURCE_CONFLICT|PRODUCT_SOURCE_CONFLICT|PRODUCT_INVALID|OUT_OF_STOCK|BAD_QTY|COUPON_INVALID|COUPON_NOT_APPLICABLE|DISCOUNT_NOT_ALLOWED|DISCOUNT_MOTIVO_REQUIRED|PAYMENT_MISMATCH|BAD_PAYMENT_METHOD|FIADO_DUE_REQUIRED|PERIOD_CLOSED|BARBER_OFF|CLIENT_INVALID|WALKIN_INVALID|WALKIN_CONFLICT/
const errOf = (m) => (String(m).match(CODES) || [String(m).match(/permission denied|deadlock detected|40P01/) || '?'])[0]
const noDeadlock = (m) => !/deadlock detected|40P01/.test(String(m))
const noDeadlockAll = (a) => a.every((x) => x.ok || noDeadlock(x.err))

// serviços do catálogo
const SVC30 = 1, SVC45 = 2, SVC15 = 5   // Corte Social 30 / Corte Degradê 45 / Acabamento 15

let CLI, CLI2, BARBA, BARBB, VEND, ADM, HYB
let PROD_A, PROD_B, PROD_LAST   // ids de produtos de teste
const HOJE = psql(`select (now() at time zone (select timezone from public.shop_settings where id=1))::date::text;`)

async function signup(tag) {
  const email = `${PFX}-${tag}@prime-lab.local`
  const r = await fetch(`${LAB}/auth/v1/signup`, { method: 'POST', headers: anonH, body: JSON.stringify({ email, password: 'Test-1234!' }) })
  const d = await r.json()
  if (!d.user?.id) throw new Error(`signup ${tag}: ${JSON.stringify(d)}`)
  return { uid: d.user.id, email }
}

// seed de atendimento EM ANDAMENTO (status confirmado + iniciado_em)
const seedAppt = ({ barber, client = null, name, email = null, services = "array['Corte Degradê']", status = 'confirmado', started = true, discount = 'null', motivo = 'null' }) =>
  Number(psql(`insert into public.appointments
    (client_id, barber_id, services, day, day_label, time, duration, status, is_encaixe, iniciado_em, client_name, client_email, discount_price, discount_motivo)
    values (${client ? `'${client}'` : 'null'}, '${barber}', ${services}, date '${HOJE}', 'x', '10:00', 45, '${status}', false,
            ${started ? 'now()' : 'null'}, '${name}', ${email ? `'${email}'` : 'null'}, ${discount}, ${motivo === 'null' ? 'null' : `'${motivo}'`})
    returning id;`))
const apptCol = (id, c) => psql(`select coalesce(${c}::text,'<null>') from public.appointments where id=${id};`)
const salesOf = (nota) => psql(`select coalesce(jsonb_agg(jsonb_build_object('svc',service,'val',value,'t',coalesce(type,'servico'),'u',unit_price,'d',discount) order by id)::text,'[]') from public.sales where nota_id=${nota};`)
const paysOf = (nota) => psql(`select coalesce(jsonb_agg(jsonb_build_object('m',method,'v',value) order by id)::text,'[]') from public.sale_payments where nota_id=${nota};`)
const notaOf = (r) => { try { return JSON.parse(r.out).nota_id } catch { return null } }
const j = (r) => { try { return JSON.parse(r.out) } catch { return null } }

const CO = (opts) => {
  // opts: {appt, barber, client_ref, service_ids, discount, products, payments, notes, key}
  const a = opts.appt ? `p_appt_id => ${opts.appt}` : 'p_appt_id => null'
  const parts = [a]
  if (opts.barber) parts.push(`p_barber_id => '${opts.barber}'`)
  if (opts.client_ref) parts.push(`p_client_ref => '${JSON.stringify(opts.client_ref)}'::jsonb`)
  if (opts.service_ids) parts.push(`p_service_ids => array[${opts.service_ids.join(',')}]::bigint[]`)
  if (opts.discount) parts.push(`p_discount => '${JSON.stringify(opts.discount)}'::jsonb`)
  if (opts.products) parts.push(`p_products => '${JSON.stringify(opts.products)}'::jsonb`)
  parts.push(`p_payments => '${JSON.stringify(opts.payments || [])}'::jsonb`)
  if (opts.notes) parts.push(`p_notes => '${opts.notes}'`)
  parts.push(`p_idempotency_key => '${opts.key || randomUUID()}'::uuid`)
  return `select public.staff_checkout(${parts.join(', ')});`
}
const cartAdd = (appt, pid, qty = 1) => `select public.staff_cart_add_item(${appt}, ${pid}, ${qty});`
const cartSetSvc = (appt, ids, disc) => `select public.staff_cart_set_services(${appt}, array[${ids.join(',')}]::bigint[]${disc ? `, '${JSON.stringify(disc)}'::jsonb` : ''});`
const cartGet = (appt) => `select public.staff_checkout_get(${appt});`

const clearAppt = (barber) => psql(`
  delete from public.notifications where appt_id in (select id from public.appointments where barber_id='${barber}' and client_name like 'st2-%');
  delete from public.cart_items where appointment_id in (select id from public.appointments where barber_id='${barber}' and client_name like 'st2-%');
  delete from public.sales where barber_id='${barber}';
  delete from public.sale_payments where barber_id='${barber}';
  delete from public.fiado_charges where barber_id='${barber}';
  delete from public.staff_checkout_log where barber_id='${barber}';
  delete from public.appointments where barber_id='${barber}' and client_name like 'st2-%';`)
const resetStock = () => psql(`update public.products set stock=20 where id in (${PROD_A},${PROD_B}); update public.products set stock=1 where id=${PROD_LAST};`)

async function seed() {
  CLI = await signup('cli'); CLI2 = await signup('cli2')
  BARBA = await signup('barbA'); BARBB = await signup('barbB')
  VEND = await signup('vend'); ADM = await signup('adm'); HYB = await signup('hyb')
  psql(`insert into public.clients (id,email,name) values
    ('${CLI.uid}','${CLI.email}','${PFX} Cliente'),
    ('${CLI2.uid}','${CLI2.email}','${PFX} Cliente2'),
    ('${HYB.uid}','${HYB.email}','${PFX} Hyb');`)
  psql(`insert into public.barbers (id,name,email,role,is_barber,commission_pct) values
    ('${BARBA.uid}','${PFX} BarbA','${BARBA.email}','barbeiro',true,0.6),
    ('${BARBB.uid}','${PFX} BarbB','${BARBB.email}','barbeiro',true,0.6),
    ('${VEND.uid}','${PFX} Vend','${VEND.email}','vendas',false,null),
    ('${ADM.uid}','${PFX} Adm','${ADM.email}','admin',false,null),
    ('${HYB.uid}','${PFX} Hyb','${HYB.email}','barbeiro',true,0.6);`)
  PROD_A = Number(psql(`insert into public.products (name,price,stock,cost,category) values ('${PFX} ProdA',10,20,3,'Geladeira') returning id;`))
  PROD_B = Number(psql(`insert into public.products (name,price,stock,cost,category) values ('${PFX} ProdB',25,20,8,'Cabelo e Barba') returning id;`))
  PROD_LAST = Number(psql(`insert into public.products (name,price,stock,cost,category) values ('${PFX} ProdLast',7,1,2,'Geladeira') returning id;`))
}

async function main() {
  console.log(`\n╔══ ST-2 — matriz de checkout (lab, prefixo ${PFX}) ══╗`)
  console.log('· aplicando ST-2.1–6 (idempotente) ...')
  for (const f of FILES) psqlFile(new URL(f, MIG).pathname)
  await reloadPgrst()
  await seed()
  console.log(`· seed ok — hoje=${HOJE} · prodA=${PROD_A} prodB=${PROD_B} prodLast=${PROD_LAST}\n`)

  // ════════════ V — matriz por papel ════════════
  console.log('── V — papel ──')
  {
    // V1 barbeiro finaliza o próprio (serviço 45 + 2×prodA 20 = 65 ; split dinheiro 40 + credito 25)
    clearAppt(BARBA.uid); resetStock()
    let a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} v1`, email: CLI.email })
    callAs(BARBA.uid, cartAdd(a, PROD_A, 2))
    let r = tryCallAs(BARBA.uid, CO({ appt: a, payments: [{ method: 'dinheiro', value: 40 }, { method: 'credito', value: 25, parcelas: 2, bandeira: 'Visa', nsu: '999' }] }))
    let n = notaOf(r)
    ok('V1 barbeiro finaliza o próprio → recibo', r.ok && n > 0, r.ok ? `nota ${n} total ${j(r).total}` : ERR(r.err))
    ok('V1 3 linhas sales (1 svc + 2 prod? não — 1 prod line com qty 2) mesmo nota_id', n && JSON.parse(salesOf(n)).length === 2, salesOf(n))
    ok('V1 Σ sale_payments = total (65)', n && psql(`select coalesce(sum(value),0) from public.sale_payments where nota_id=${n};`) === '65.00', paysOf(n))
    ok('V1 appt=concluido, cart limpo, estoque −2', apptCol(a, 'status') === 'concluido'
      && psql(`select count(*) from public.cart_items where appointment_id=${a};`) === '0'
      && psql(`select stock from public.products where id=${PROD_A};`) === '18',
      `st=${apptCol(a, 'status')} stock=${psql(`select stock from public.products where id=${PROD_A};`)}`)
    ok('V1 sales.barber_id = BarbA', n && psql(`select distinct barber_id from public.sales where nota_id=${n};`) === BARBA.uid)
    ok('V1 notificação concluido ao cliente (só conta)', n && psql(`select count(*) from public.notifications where appt_id=${a} and type='concluido' and for_role='client';`) === '1')
    ok('V1 staff_checkout_log gravado', n && psql(`select count(*) from public.staff_checkout_log where nota_id=${n};`) === '1')
    clearAppt(BARBA.uid)

    // V2 barbeiro finaliza atendimento de OUTRO barbeiro → NOT_FOUND
    a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} v2`, email: CLI.email })
    r = tryCallAs(BARBB.uid, CO({ appt: a, payments: [{ method: 'dinheiro', value: 45 }] }))
    ok('V2 barbeiro B finaliza appt de A → NOT_FOUND, nada gravado', !r.ok && /NOT_FOUND/.test(r.err)
      && apptCol(a, 'status') === 'confirmado' && psql(`select count(*) from public.sales where barber_id='${BARBA.uid}';`) === '0', errOf(r.err))
    clearAppt(BARBA.uid)

    // V3 vendas finaliza "em nome de" A
    a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} v3`, email: CLI.email })
    r = tryCallAs(VEND.uid, CO({ appt: a, payments: [{ method: 'pix_direto', value: 45 }] }))
    n = notaOf(r)
    ok('V3 vendas finaliza appt de A → ok, sales.barber_id = A (não o vendas)',
      r.ok && n && psql(`select distinct barber_id from public.sales where nota_id=${n};`) === BARBA.uid, r.ok ? `nota ${n}` : ERR(r.err))
    clearAppt(BARBA.uid)

    // V4 admin finaliza appt de B
    a = seedAppt({ barber: BARBB.uid, client: CLI.uid, name: `${PFX} v4`, email: CLI.email })
    r = tryCallAs(ADM.uid, CO({ appt: a, payments: [{ method: 'debito', value: 45, bandeira: 'Elo' }] }))
    ok('V4 admin finaliza appt de B → ok', r.ok && notaOf(r) > 0, r.ok ? `nota ${notaOf(r)}` : ERR(r.err))
    clearAppt(BARBB.uid)

    // V5 cliente / V6 anon
    a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} v5`, email: CLI.email })
    r = tryCallAs(CLI.uid, CO({ appt: a, payments: [{ method: 'dinheiro', value: 45 }] }))
    ok('V5 cliente chama staff_checkout → NOT_STAFF', !r.ok && /NOT_STAFF/.test(r.err), errOf(r.err))
    r = tryCallAs(null, CO({ appt: a, payments: [{ method: 'dinheiro', value: 45 }] }))
    ok('V6 anon chama staff_checkout → negado', !r.ok && /permission denied|NOT_AUTH|42501/.test(r.err), ERR(r.err))
    clearAppt(BARBA.uid)

    // V7 híbrido finaliza a própria linha-como-cliente (barbeiro é B)
    a = seedAppt({ barber: BARBB.uid, client: HYB.uid, name: `${PFX} v7`, email: HYB.email })
    r = tryCallAs(HYB.uid, CO({ appt: a, payments: [{ method: 'dinheiro', value: 45 }] }))
    ok('V7 híbrido finaliza a própria linha-como-cliente (barbeiro é B) → NOT_FOUND', !r.ok && /NOT_FOUND/.test(r.err), errOf(r.err))
    clearAppt(BARBB.uid)

    // V8 balcão walk-in (sem conta), só produtos
    resetStock()
    r = tryCallAs(BARBA.uid, CO({ barber: BARBA.uid, client_ref: { mode: 'walkin', name: `${PFX} Ze Balcao`, phone: '11988887777' },
      products: [{ product_id: PROD_B, qty: 1 }], payments: [{ method: 'dinheiro', value: 25 }] }))
    n = notaOf(r)
    ok('V8 balcão walk-in só produtos → sales sem appointment_id, client_name = walk-in, crm criado, sem retroativo',
      r.ok && n && psql(`select coalesce(appointment_id::text,'null') from public.sales where nota_id=${n} limit 1;`) === 'null'
      && psql(`select client_name from public.sales where nota_id=${n} limit 1;`) === `${PFX} Ze Balcao`
      && psql(`select count(*) from public.crm_clients where barber_id='${BARBA.uid}' and lower(name)=lower('${PFX} Ze Balcao');`) === '1'
      && psql(`select count(*) from public.appointments where barber_id='${BARBA.uid}' and client_name='${PFX} Ze Balcao';`) === '0',
      r.ok ? `nota ${n}` : ERR(r.err))
    clearAppt(BARBA.uid)

    // V9 balcão conta + serviço → cria retroativo concluido
    resetStock()
    r = tryCallAs(BARBA.uid, CO({ barber: BARBA.uid, client_ref: { mode: 'account', id: CLI.uid },
      service_ids: [SVC30], products: [{ product_id: PROD_A, qty: 1 }], payments: [{ method: 'dinheiro', value: 40 }] }))
    n = notaOf(r)
    const retroId = n && psql(`select distinct appointment_id from public.sales where nota_id=${n} and appointment_id is not null;`)
    ok('V9 balcão conta + serviço → retroativo concluido na transação + venda vinculada',
      r.ok && n && retroId && apptCol(retroId, 'status') === 'concluido' && apptCol(retroId, 'client_id') === CLI.uid,
      r.ok ? `nota ${n} appt ${retroId}` : ERR(r.err))
    clearAppt(BARBA.uid)
  }

  // ════════════ AB — isolamento ════════════
  console.log('\n── AB — isolamento ──')
  {
    clearAppt(BARBA.uid); clearAppt(BARBB.uid)
    const a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} ab`, email: CLI.email })
    let r = tryCallAs(BARBB.uid, cartGet(a))
    ok('AB barbeiro B lê staff_checkout_get de appt de A → NOT_FOUND', !r.ok && /NOT_FOUND/.test(r.err), errOf(r.err))
    r = tryCallAs(VEND.uid, cartGet(a))
    ok('AB vendas lê staff_checkout_get de qualquer appt → ok', r.ok && j(r)?.appt?.id === a, r.ok ? 'ok' : ERR(r.err))
    r = tryCallAs(ADM.uid, cartGet(a))
    ok('AB admin lê → ok', r.ok && j(r)?.appt?.id === a, r.ok ? 'ok' : ERR(r.err))
    // cliente não lê sales de ninguém
    r = tryCallAs(CLI.uid, `select count(*) from public.sales;`)
    ok('AB cliente SELECT sales → 0 linhas (RLS)', r.ok && r.out === '0', r.out || ERR(r.err))
    clearAppt(BARBA.uid)
  }

  // ════════════ C — corridas ════════════
  console.log('\n── C — corridas (idempotência atômica) ──')
  {
    // C1a agenda, mesma key, 2 simultâneos
    let doubles = 0, iters = 6
    for (let i = 0; i < iters; i++) {
      clearAppt(BARBA.uid); resetStock()
      const a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} c1a-${i}`, email: CLI.email })
      const k = randomUUID()
      const sql = CO({ appt: a, payments: [{ method: 'dinheiro', value: 45 }], key: k })
      const res = await Promise.all([callAsP(BARBA.uid, sql), callAsP(BARBA.uid, sql)])
      const notas = res.filter((x) => x.ok).map((x) => notaOf(x))
      const nrows = psql(`select count(distinct nota_id) from public.sales where barber_id='${BARBA.uid}';`)
      if (res.filter((x) => x.ok).length !== 2 || new Set(notas).size !== 1 || nrows !== '1' || !noDeadlockAll(res)) doubles++
    }
    ok(`C1a ${iters}× agenda mesma key → mesmo nota_id, 1 venda, ambos retornam recibo`, doubles === 0, `doubles=${doubles}`)
    clearAppt(BARBA.uid)

    // C1b BALCÃO, mesma key, 2 simultâneos
    doubles = 0; iters = 6
    for (let i = 0; i < iters; i++) {
      clearAppt(BARBA.uid); resetStock()
      const k = randomUUID()
      const sql = CO({ barber: BARBA.uid, client_ref: { mode: 'walkin', name: `${PFX} c1b`, phone: '11970000001' },
        products: [{ product_id: PROD_B, qty: 1 }], payments: [{ method: 'dinheiro', value: 25 }], key: k })
      const res = await Promise.all([callAsP(BARBA.uid, sql), callAsP(BARBA.uid, sql)])
      const notas = res.filter((x) => x.ok).map((x) => notaOf(x))
      const nrows = psql(`select count(distinct nota_id) from public.sales where barber_id='${BARBA.uid}';`)
      if (res.filter((x) => x.ok).length !== 2 || new Set(notas).size !== 1 || nrows !== '1' || !noDeadlockAll(res)) doubles++
    }
    ok(`C1b ${iters}× BALCÃO mesma key → mesmo nota_id, 1 venda (o _lock_checkout serializa antes de escrever)`, doubles === 0, `doubles=${doubles}`)
    clearAppt(BARBA.uid)

    // C1c N=5 mesma key
    clearAppt(BARBA.uid); resetStock()
    let a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} c1c`, email: CLI.email })
    let k = randomUUID()
    let sql = CO({ appt: a, payments: [{ method: 'dinheiro', value: 45 }], key: k })
    let res = await Promise.all([1, 2, 3, 4, 5].map(() => callAsP(BARBA.uid, sql)))
    ok('C1c 5× mesma key → 5 ok, 1 nota, 1 venda',
      res.every((x) => x.ok) && new Set(res.map((x) => notaOf(x))).size === 1
      && psql(`select count(distinct nota_id) from public.sales where barber_id='${BARBA.uid}';`) === '1', `oks=${res.filter((x) => x.ok).length}`)
    clearAppt(BARBA.uid)

    // C1d mesma key, inputs diferentes
    clearAppt(BARBA.uid); resetStock()
    a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} c1d`, email: CLI.email })
    k = randomUUID()
    let r1 = tryCallAs(BARBA.uid, CO({ appt: a, payments: [{ method: 'dinheiro', value: 45 }], key: k }))
    // 2a: mesmo key, payments diferentes → IDEMPOTENCY_MISMATCH
    let r2 = tryCallAs(BARBA.uid, CO({ appt: a, payments: [{ method: 'credito', value: 45 }], key: k }))
    ok('C1d mesma key + inputs diferentes → 1a ok, 2a IDEMPOTENCY_MISMATCH', r1.ok && !r2.ok && /IDEMPOTENCY_MISMATCH/.test(r2.err), errOf(r2.err))
    clearAppt(BARBA.uid)

    // C1e replay por OUTRO barbeiro
    clearAppt(BARBA.uid); resetStock()
    a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} c1e`, email: CLI.email })
    k = randomUUID()
    r1 = tryCallAs(BARBA.uid, CO({ appt: a, payments: [{ method: 'dinheiro', value: 45 }], key: k }))
    r2 = tryCallAs(BARBB.uid, CO({ appt: a, payments: [{ method: 'dinheiro', value: 45 }], key: k }))
    ok('C1e replay da key por barbeiro B (não ator, não admin/vendas) → NOT_ALLOWED', r1.ok && !r2.ok && /NOT_ALLOWED/.test(r2.err), errOf(r2.err))
    // C1f replay por admin → devolve recibo
    r2 = tryCallAs(ADM.uid, CO({ appt: a, payments: [{ method: 'dinheiro', value: 45 }], key: k }))
    ok('C1f replay da key por admin → status replayed', r2.ok && j(r2)?.status === 'replayed', r2.ok ? j(r2)?.status : errOf(r2.err))
    clearAppt(BARBA.uid)

    // C1g replay pós-rollback (produto acaba no meio) → 2a sem o produto ruim → ok, venda nova
    clearAppt(BARBA.uid); resetStock()
    a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} c1g`, email: CLI.email })
    callAs(BARBA.uid, cartAdd(a, PROD_A, 1))   // adiciona com estoque ok
    psql(`update public.products set stock=0 where id=${PROD_A};`)   // depois zera → checkout falha no passo 10
    k = randomUUID()
    r1 = tryCallAs(BARBA.uid, CO({ appt: a, payments: [{ method: 'dinheiro', value: 55 }], key: k }))
    const logAfterFail = psql(`select count(*) from public.staff_checkout_log where idempotency_key='${k}';`)
    psql(`delete from public.cart_items where appointment_id=${a}; update public.products set stock=20 where id=${PROD_A};`)
    r2 = tryCallAs(BARBA.uid, CO({ appt: a, payments: [{ method: 'dinheiro', value: 45 }], key: k }))
    ok('C1g checkout falha (OUT_OF_STOCK) → rollback, SEM log órfão; retry mesma key → ok, venda nova',
      !r1.ok && /OUT_OF_STOCK/.test(r1.err) && logAfterFail === '0' && r2.ok && notaOf(r2) > 0, `fail=${errOf(r1.err)} log=${logAfterFail} retry=${r2.ok}`)
    clearAppt(BARBA.uid)

    // C2 mesmo appt, keys diferentes → 1 vence, 1 ALREADY_CHECKED_OUT
    let bad = 0; iters = 6
    for (let i = 0; i < iters; i++) {
      clearAppt(BARBA.uid); resetStock()
      a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} c2-${i}`, email: CLI.email })
      res = await Promise.all([
        callAsP(BARBA.uid, CO({ appt: a, payments: [{ method: 'dinheiro', value: 45 }], key: randomUUID() })),
        callAsP(BARBA.uid, CO({ appt: a, payments: [{ method: 'dinheiro', value: 45 }], key: randomUUID() })),
      ])
      const wins = res.filter((x) => x.ok).length
      const acos = res.filter((x) => !x.ok && /ALREADY_CHECKED_OUT/.test(x.err)).length
      if (wins !== 1 || acos !== 1 || psql(`select count(distinct nota_id) from public.sales where barber_id='${BARBA.uid}';`) !== '1' || !noDeadlockAll(res)) bad++
    }
    ok(`C2 ${iters}× mesmo appt, keys distintas → 1 vence, 1 ALREADY_CHECKED_OUT, 1 venda`, bad === 0, `bad=${bad}`)
    clearAppt(BARBA.uid)

    // C3 checkout ‖ staff_reschedule_appointment do mesmo appt
    bad = 0; iters = 6
    const THU = psql(`select g::date::text from generate_series((now() at time zone (select timezone from public.shop_settings where id=1))::date+1,(now() at time zone (select timezone from public.shop_settings where id=1))::date+9,interval '1 day') g where extract(dow from g)=4 order by g limit 1;`)
    for (let i = 0; i < iters; i++) {
      clearAppt(BARBA.uid); resetStock()
      a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} c3-${i}`, email: CLI.email })
      res = await Promise.all([
        callAsP(BARBA.uid, CO({ appt: a, payments: [{ method: 'dinheiro', value: 45 }], key: randomUUID() })),
        callAsP(BARBA.uid, `select public.staff_reschedule_appointment(${a}, date '${THU}', '11:00');`),
      ])
      if (!noDeadlockAll(res)) bad++
      // se o checkout venceu → appt concluido (staff_reschedule falha NOT_RESCHEDULABLE pq iniciado); se resched venceu → checkout BAD_STATE/NOT_FOUND
      const st = apptCol(a, 'status')
      const okCase = (res[0].ok && st === 'concluido') || (!res[0].ok && CODES.test(res[0].err))
      if (!okCase) bad++
    }
    ok(`C3 ${iters}× checkout ‖ staff_reschedule → 0 40P01, estado coerente`, bad === 0, `bad=${bad}`)
    clearAppt(BARBA.uid)

    // C4 checkout ‖ staff_cancel_appointment
    bad = 0; iters = 6
    for (let i = 0; i < iters; i++) {
      clearAppt(BARBA.uid); resetStock()
      a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} c4-${i}`, email: CLI.email })
      res = await Promise.all([
        callAsP(BARBA.uid, CO({ appt: a, payments: [{ method: 'dinheiro', value: 45 }], key: randomUUID() })),
        callAsP(BARBA.uid, `select public.staff_cancel_appointment(${a}, 'corrida');`),
      ])
      if (!noDeadlockAll(res)) bad++
      const st = apptCol(a, 'status')
      const okCase = (res[0].ok && st === 'concluido' && !res[1].ok) || (!res[0].ok && st === 'cancelado' && res[1].ok)
      if (!okCase) bad++
    }
    ok(`C4 ${iters}× checkout ‖ staff_cancel → 0 40P01; um vence, estado coerente`, bad === 0, `bad=${bad}`)
    clearAppt(BARBA.uid)

    // C5 2 checkouts de balcões diferentes → 2 nota_id distintos
    resetStock()
    res = await Promise.all([
      callAsP(BARBA.uid, CO({ barber: BARBA.uid, client_ref: { mode: 'walkin', name: `${PFX} c5a`, phone: '11960000001' }, products: [{ product_id: PROD_A, qty: 1 }], payments: [{ method: 'dinheiro', value: 10 }], key: randomUUID() })),
      callAsP(BARBB.uid, CO({ barber: BARBB.uid, client_ref: { mode: 'walkin', name: `${PFX} c5b`, phone: '11960000002' }, products: [{ product_id: PROD_A, qty: 1 }], payments: [{ method: 'dinheiro', value: 10 }], key: randomUUID() })),
    ])
    ok('C5 2 balcões simultâneos → 2 nota_id distintos, 0 mistura',
      res.every((x) => x.ok) && new Set(res.map((x) => notaOf(x))).size === 2 && noDeadlockAll(res), `notas=${res.map((x) => notaOf(x))}`)
    clearAppt(BARBA.uid); clearAppt(BARBB.uid)

    // C6 2 vendas do último item (stock=1) — keys distintas
    bad = 0; iters = 6
    for (let i = 0; i < iters; i++) {
      clearAppt(BARBA.uid); clearAppt(BARBB.uid); resetStock()  // PROD_LAST stock=1
      res = await Promise.all([
        callAsP(BARBA.uid, CO({ barber: BARBA.uid, client_ref: { mode: 'walkin', name: `${PFX} c6a`, phone: '11950000001' }, products: [{ product_id: PROD_LAST, qty: 1 }], payments: [{ method: 'dinheiro', value: 7 }], key: randomUUID() })),
        callAsP(BARBB.uid, CO({ barber: BARBB.uid, client_ref: { mode: 'walkin', name: `${PFX} c6b`, phone: '11950000002' }, products: [{ product_id: PROD_LAST, qty: 1 }], payments: [{ method: 'dinheiro', value: 7 }], key: randomUUID() })),
      ])
      const wins = res.filter((x) => x.ok).length
      const oos = res.filter((x) => !x.ok && /OUT_OF_STOCK/.test(x.err)).length
      const stk = psql(`select stock from public.products where id=${PROD_LAST};`)
      if (wins !== 1 || oos !== 1 || stk !== '0' || !noDeadlockAll(res)) bad++
    }
    ok(`C6 ${iters}× 2 vendas do último item → 1 vende, 1 OUT_OF_STOCK, stock final 0`, bad === 0, `bad=${bad}`)
    clearAppt(BARBA.uid); clearAppt(BARBB.uid); resetStock()

    // C7 pg_locks: 0 40P01 em toda a matriz C (coberto acima); prova o advisory checkout|
    {
      const hold = spawn('docker', PSQL)
      hold.stdin.write(`begin;\nselect public._lock_checkout('00000000-0000-0000-0000-0000000000c7'::uuid);\n`)
      await sleep(300)
      const held = psql(`with kk as (select hashtextextended('checkout|00000000-0000-0000-0000-0000000000c7',0) key)
        select exists(select 1 from pg_locks l, kk where l.locktype='advisory' and l.objsubid=1
          and l.classid::bigint=((kk.key>>32)&4294967295) and l.objid::bigint=(kk.key&4294967295))::text;`)
      hold.stdin.write('rollback;\n'); hold.stdin.end(); await sleep(150)
      ok('C7 _lock_checkout usa advisory hashtextextended(\'checkout|<key>\')', held === 'true', `held=${held}`)
    }
  }

  // ════════════ F — adulteração / regras ════════════
  console.log('\n── F — adulteração / regras ──')
  {
    clearAppt(BARBA.uid); resetStock()
    const mk = () => seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} f`, email: CLI.email })
    let a, r

    a = mk(); r = tryCallAs(BARBA.uid, CO({ appt: a, payments: [{ method: 'dinheiro', value: 40 }] }))
    ok('F1 pagamento MENOR que o total → PAYMENT_MISMATCH, nada gravado', !r.ok && /PAYMENT_MISMATCH/.test(r.err) && apptCol(a, 'status') === 'confirmado', errOf(r.err)); clearAppt(BARBA.uid)

    a = mk(); r = tryCallAs(BARBA.uid, CO({ appt: a, payments: [{ method: 'credito', value: 60, bandeira: 'Visa' }] }))
    ok('F2 pagamento MAIOR, excedente em crédito → PAYMENT_MISMATCH (troco só dinheiro)', !r.ok && /PAYMENT_MISMATCH/.test(r.err), errOf(r.err)); clearAppt(BARBA.uid)

    a = mk(); r = tryCallAs(BARBA.uid, CO({ appt: a, payments: [{ method: 'dinheiro', value: 100 }] }))
    let n = notaOf(r)
    ok('F3 pagamento MAIOR em dinheiro → ok, Σ sale_payments = total (45), recibo mostra troco 55',
      r.ok && n && psql(`select sum(value) from public.sale_payments where nota_id=${n};`) === '45.00' && j(r).troco === 55, r.ok ? `troco=${j(r).troco}` : ERR(r.err)); clearAppt(BARBA.uid)

    // F4 teto por papel
    a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} f4`, email: CLI.email })
    r = tryCallAs(BARBA.uid, cartSetSvc(a, [SVC45], { mode: 'pct', pct: 16 }))
    ok('F4 barbeiro tenta 16% (teto 15) → DISCOUNT_NOT_ALLOWED', !r.ok && /DISCOUNT_NOT_ALLOWED/.test(r.err), errOf(r.err))
    r = tryCallAs(VEND.uid, cartSetSvc(a, [SVC45], { mode: 'pct', pct: 21 }))
    ok('F4 vendas tenta 21% (teto 20) → DISCOUNT_NOT_ALLOWED', !r.ok && /DISCOUNT_NOT_ALLOWED/.test(r.err), errOf(r.err))
    r = tryCallAs(ADM.uid, cartSetSvc(a, [SVC45], { mode: 'pct', pct: 25 }))
    ok('F4 admin 25% SEM motivo (>threshold 20) → DISCOUNT_MOTIVO_REQUIRED', !r.ok && /DISCOUNT_MOTIVO_REQUIRED/.test(r.err), errOf(r.err))
    r = tryCallAs(ADM.uid, cartSetSvc(a, [SVC45], { mode: 'pct', pct: 25, motivo: 'cliente fiel há 5 anos' }))
    ok('F4 admin 25% COM motivo → ok, discount_price 33.75, motivo persistido',
      r.ok && apptCol(a, 'discount_price') === '33.75' && apptCol(a, 'discount_motivo') === 'cliente fiel há 5 anos', r.ok ? `dp=${apptCol(a, 'discount_price')}` : ERR(r.err))
    r = tryCallAs(BARBA.uid, cartSetSvc(a, [SVC45], { mode: 'pct', pct: 10 }))
    ok('F4 barbeiro 10% → ok, discount_price 40.50, motivo null', r.ok && apptCol(a, 'discount_price') === '40.50' && apptCol(a, 'discount_motivo') === '<null>', r.ok ? `dp=${apptCol(a, 'discount_price')}` : ERR(r.err))
    // F4b acréscimo
    r = tryCallAs(ADM.uid, cartSetSvc(a, [SVC45], { mode: 'manual', price: 60 }))
    ok('F4b acréscimo (price 60 > tabela 45) → DISCOUNT_NOT_ALLOWED', !r.ok && /DISCOUNT_NOT_ALLOWED/.test(r.err), errOf(r.err))
    clearAppt(BARBA.uid)

    // F5/F6 cupom (via cart_set_services)
    a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} f5`, email: CLI.email, services: "array['Corte Social']" })
    r = tryCallAs(BARBA.uid, cartSetSvc(a, [SVC30], { mode: 'coupon', code: 'INEXISTENTE' }))
    ok('F5 cupom inexistente → COUPON_INVALID', !r.ok && /COUPON_INVALID/.test(r.err), errOf(r.err))
    r = tryCallAs(BARBA.uid, cartSetSvc(a, [SVC30, SVC45], { mode: 'coupon', code: 'PRIMEIROCORTE' }))
    ok('F6 cupom com escopo + 2 serviços → COUPON_NOT_APPLICABLE', !r.ok && /COUPON_NOT_APPLICABLE/.test(r.err), errOf(r.err))
    r = tryCallAs(BARBA.uid, cartSetSvc(a, [SVC30], { mode: 'coupon', code: 'PRIMEIROCORTE' }))
    ok('F6 cupom PRIMEIROCORTE em Corte Social (R$30) → discount_price 24.99, sem motivo (cupom exento)',
      r.ok && apptCol(a, 'discount_price') === '24.99' && apptCol(a, 'coupon_code') === 'PRIMEIROCORTE' && apptCol(a, 'discount_motivo') === '<null>', r.ok ? `dp=${apptCol(a, 'discount_price')}` : ERR(r.err))
    clearAppt(BARBA.uid)

    // F7 serviços inválidos (balcão)
    r = tryCallAs(BARBA.uid, CO({ barber: BARBA.uid, client_ref: { mode: 'account', id: CLI.uid }, service_ids: [999999], payments: [{ method: 'dinheiro', value: 10 }] }))
    ok('F7 balcão service_id inexistente → SERVICE_INVALID', !r.ok && /SERVICE_INVALID/.test(r.err), errOf(r.err))

    // F8/F9 produtos
    r = tryCallAs(BARBA.uid, CO({ barber: BARBA.uid, client_ref: { mode: 'account', id: CLI.uid }, products: [{ product_id: 999999, qty: 1 }], payments: [{ method: 'dinheiro', value: 1 }] }))
    ok('F8 balcão product_id inexistente → PRODUCT_INVALID', !r.ok && /PRODUCT_INVALID/.test(r.err), errOf(r.err))
    r = tryCallAs(BARBA.uid, CO({ barber: BARBA.uid, client_ref: { mode: 'account', id: CLI.uid }, products: [{ product_id: PROD_A, qty: 0 }], payments: [{ method: 'dinheiro', value: 1 }] }))
    ok('F8 qty 0 → BAD_QTY', !r.ok && /BAD_QTY/.test(r.err), errOf(r.err))
    resetStock()
    r = tryCallAs(BARBA.uid, CO({ barber: BARBA.uid, client_ref: { mode: 'account', id: CLI.uid }, products: [{ product_id: PROD_LAST, qty: 5 }], payments: [{ method: 'dinheiro', value: 35 }] }))
    ok('F9 qty > stock → OUT_OF_STOCK, nada gravado', !r.ok && /OUT_OF_STOCK/.test(r.err) && psql(`select stock from public.products where id=${PROD_LAST};`) === '1', errOf(r.err))

    // F10/F11
    a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} f10`, email: CLI.email, status: 'confirmado', started: false })
    r = tryCallAs(BARBA.uid, CO({ appt: a, payments: [{ method: 'dinheiro', value: 45 }] }))
    ok('F10 appt não iniciado → BAD_STATE', !r.ok && /BAD_STATE/.test(r.err), errOf(r.err)); clearAppt(BARBA.uid)
    a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} f11`, email: CLI.email, status: 'concluido' })
    r = tryCallAs(BARBA.uid, CO({ appt: a, payments: [{ method: 'dinheiro', value: 45 }] }))
    ok('F11 appt já concluido → ALREADY_CHECKED_OUT', !r.ok && /ALREADY_CHECKED_OUT/.test(r.err), errOf(r.err)); clearAppt(BARBA.uid)

    // F12/F13
    a = mk(); r = tryCallAs(BARBA.uid, CO({ appt: a, payments: [{ method: 'boleto', value: 45 }] }))
    ok('F12 método fora do enum → BAD_PAYMENT_METHOD', !r.ok && /BAD_PAYMENT_METHOD/.test(r.err), errOf(r.err)); clearAppt(BARBA.uid)
    a = mk(); r = tryCallAs(BARBA.uid, CO({ appt: a, payments: [{ method: 'a_prazo', value: 45 }] }))
    ok('F13 a_prazo sem due_date → FIADO_DUE_REQUIRED', !r.ok && /FIADO_DUE_REQUIRED/.test(r.err), errOf(r.err))
    r = tryCallAs(BARBA.uid, CO({ appt: a, payments: [{ method: 'a_prazo', value: 45, due_date: HOJE }] }))
    ok('F13 a_prazo due_date = hoje (não futura) → FIADO_DUE_REQUIRED', !r.ok && /FIADO_DUE_REQUIRED/.test(r.err), errOf(r.err))
    const FUT = psql(`select ((now() at time zone (select timezone from public.shop_settings where id=1))::date + 30)::text;`)
    r = tryCallAs(BARBA.uid, CO({ appt: a, payments: [{ method: 'a_prazo', value: 45, due_date: FUT }] }))
    n = notaOf(r)
    ok('F13 a_prazo due_date futura → ok + fiado_charges aberto', r.ok && n && psql(`select status from public.fiado_charges where nota_id=${n};`) === 'aberto', r.ok ? `nota ${n}` : ERR(r.err))
    clearAppt(BARBA.uid)

    // F14 source conflict (caminho agenda com params)
    a = mk()
    r = tryCallAs(BARBA.uid, CO({ appt: a, service_ids: [SVC45], payments: [{ method: 'dinheiro', value: 45 }] }))
    ok('F14 caminho agenda + p_service_ids → SERVICE_SOURCE_CONFLICT', !r.ok && /SERVICE_SOURCE_CONFLICT/.test(r.err), errOf(r.err))
    r = tryCallAs(BARBA.uid, CO({ appt: a, discount: { mode: 'none' }, payments: [{ method: 'dinheiro', value: 45 }] }))
    ok('F14 caminho agenda + p_discount → DISCOUNT_SOURCE_CONFLICT', !r.ok && /DISCOUNT_SOURCE_CONFLICT/.test(r.err), errOf(r.err))
    r = tryCallAs(BARBA.uid, CO({ appt: a, products: [{ product_id: PROD_A, qty: 1 }], payments: [{ method: 'dinheiro', value: 55 }] }))
    ok('F14 caminho agenda + p_products → PRODUCT_SOURCE_CONFLICT', !r.ok && /PRODUCT_SOURCE_CONFLICT/.test(r.err), errOf(r.err))
    clearAppt(BARBA.uid)

    // F15/F16 período fechado (data de finalização)
    psql(`insert into public.cash_closures (period_from, period_to, expected_value, counted_value, difference, admin_id) values (date '${HOJE}', date '${HOJE}', 0, 0, 0, '${ADM.uid}');`)
    a = mk(); r = tryCallAs(BARBA.uid, CO({ appt: a, payments: [{ method: 'dinheiro', value: 45 }] }))
    ok('F16 finaliza hoje dentro de cash_closures fechado → PERIOD_CLOSED (data de finalização)', !r.ok && /PERIOD_CLOSED/.test(r.err), errOf(r.err))
    psql(`delete from public.cash_closures where admin_id='${ADM.uid}';`)
    r = tryCallAs(BARBA.uid, CO({ appt: a, payments: [{ method: 'dinheiro', value: 45 }] }))
    ok('F15 mesmo appt, período reaberto → ok, sales.date = hoje', r.ok && notaOf(r) > 0 && psql(`select distinct date::text from public.sales where nota_id=${notaOf(r)};`) === HOJE, r.ok ? 'ok' : ERR(r.err))
    clearAppt(BARBA.uid)

    // F17 params forjados ignorados
    a = mk(); r = tryCallAs(BARBA.uid, CO({ appt: a, payments: [{ method: 'dinheiro', value: 45 }] }))
    n = notaOf(r)
    ok('F17 servidor resolve value/date/client_name (browser não manda) → linha coerente',
      r.ok && n && psql(`select value from public.sales where nota_id=${n} and type is null;`) === '45.00'
      && psql(`select client_name from public.sales where nota_id=${n} limit 1;`) === `${PFX} f`, r.ok ? 'ok' : ERR(r.err))
    clearAppt(BARBA.uid)

    // F18/F19/F20 decrement_product_stock reescrito
    r = tryCallAs(null, `select public.decrement_product_stock(${PROD_A}, 1);`)
    ok('F18 decrement_product_stock por anon → negado', !r.ok && /permission denied|42501/.test(r.err), ERR(r.err))
    r = tryCallAs(CLI.uid, `select public.decrement_product_stock(${PROD_A}, 1);`)
    ok('F19 decrement_product_stock por cliente logado → NOT_STAFF', !r.ok && /NOT_STAFF/.test(r.err), errOf(r.err))
    resetStock()
    r = tryCallAs(BARBA.uid, `select public.decrement_product_stock(${PROD_A}, 1);`)
    ok('F20 decrement_product_stock por barbeiro logado (legado) → ok', r.ok && r.out === '19', r.ok ? `stock=${r.out}` : ERR(r.err))
    resetStock()

    // F21 validate_coupon por anon
    r = tryCallAs(null, `select * from public.validate_coupon('PRIMEIROCORTE');`)
    ok('F21 validate_coupon por anon (pós-revoke) → negado', !r.ok && /permission denied|42501/.test(r.err), ERR(r.err))
    r = tryCallAs(CLI.uid, `select code from public.validate_coupon('PRIMEIROCORTE');`)
    ok('F21 validate_coupon por cliente logado → ok (wizard segue)', r.ok && r.out === 'PRIMEIROCORTE', r.ok ? 'ok' : ERR(r.err))

    // F22 key inválida / ausente
    a = mk()
    r = tryCallAs(BARBA.uid, `select public.staff_checkout(p_appt_id => ${a}, p_payments => '[{"method":"dinheiro","value":45}]'::jsonb);`)
    ok('F22 staff_checkout sem p_idempotency_key → BAD_INPUT', !r.ok && /BAD_INPUT/.test(r.err), errOf(r.err))
    clearAppt(BARBA.uid)
  }

  // ════════════ A — atomicidade ════════════
  console.log('\n── A — atomicidade ──')
  {
    clearAppt(BARBA.uid); resetStock()
    // A1: 2 produtos no carrinho, o 2o sem estoque → nada gravado
    const a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} a1`, email: CLI.email })
    callAs(BARBA.uid, cartAdd(a, PROD_A, 1))
    callAs(BARBA.uid, cartAdd(a, PROD_B, 1))
    // depois zera o estoque do 2o → o checkout monta 2 linhas mas o passo 10 (decremento) falha na 2a
    psql(`update public.products set stock=20 where id=${PROD_A}; update public.products set stock=0 where id=${PROD_B};`)
    const seqBefore = psql(`select last_value from public.sales_nota_seq;`)
    const r = tryCallAs(BARBA.uid, CO({ appt: a, payments: [{ method: 'dinheiro', value: 80 }] }))
    const seqAfter = psql(`select last_value from public.sales_nota_seq;`)
    ok('A1 checkout com produto sem estoque no meio → OUT_OF_STOCK; estado ZERO',
      !r.ok && /OUT_OF_STOCK/.test(r.err)
      && psql(`select count(*) from public.sales where barber_id='${BARBA.uid}';`) === '0'
      && psql(`select count(*) from public.sale_payments where barber_id='${BARBA.uid}';`) === '0'
      && psql(`select count(*) from public.staff_checkout_log where barber_id='${BARBA.uid}';`) === '0'
      && psql(`select stock from public.products where id=${PROD_A};`) === '20'
      && apptCol(a, 'status') === 'confirmado'
      && psql(`select count(*) from public.cart_items where appointment_id=${a};`) === '2',
      `err=${errOf(r.err)}`)
    ok('A1 sales_nota_seq AVANÇOU (não faz rollback — id queimado é inofensivo, documentado)',
      Number(seqAfter) > Number(seqBefore), `${seqBefore}→${seqAfter}`)
    clearAppt(BARBA.uid); resetStock()

    // A2: balcão conta + serviço, mas pagamento não bate → nem retroativo nem venda
    const before = psql(`select count(*) from public.appointments where barber_id='${BARBA.uid}';`)
    const r2 = tryCallAs(BARBA.uid, CO({ barber: BARBA.uid, client_ref: { mode: 'account', id: CLI.uid }, service_ids: [SVC45], payments: [{ method: 'dinheiro', value: 10 }] }))
    ok('A2 balcão conta+serviço com pagamento insuficiente → PAYMENT_MISMATCH; retroativo NÃO criado',
      !r2.ok && /PAYMENT_MISMATCH/.test(r2.err) && psql(`select count(*) from public.appointments where barber_id='${BARBA.uid}';`) === before, errOf(r2.err))
    clearAppt(BARBA.uid)

    // A3: walk-in com pagamento ruim → crm_clients NÃO criado
    const r3 = tryCallAs(BARBA.uid, CO({ barber: BARBA.uid, client_ref: { mode: 'walkin', name: `${PFX} a3walk`, phone: '11940000009' }, products: [{ product_id: PROD_A, qty: 1 }], payments: [{ method: 'dinheiro', value: 5 }] }))
    ok('A3 walk-in + pagamento insuficiente → PAYMENT_MISMATCH; crm_clients NÃO criado',
      !r3.ok && /PAYMENT_MISMATCH/.test(r3.err) && psql(`select count(*) from public.crm_clients where lower(name)=lower('${PFX} a3walk');`) === '0', errOf(r3.err))
    clearAppt(BARBA.uid)
  }

  // ════════════ EV — evidências ════════════
  console.log('\n── EV — evidências ──')
  const ev = psql(`select p.proname||'|secdef='||p.prosecdef||'|sp='||coalesce(array_to_string(p.proconfig,','),'-')||'|exec='||
      coalesce((select string_agg(g.rolname,',' order by g.rolname) from aclexplode(p.proacl) a join pg_roles g on g.oid=a.grantee
        where a.privilege_type='EXECUTE' and g.rolname not in ('postgres','supabase_admin')),'owner')
    from pg_proc p where p.pronamespace='public'::regnamespace
      and p.proname in ('staff_checkout','staff_checkout_get','staff_cart_add_item','staff_cart_set_qty','staff_cart_set_services',
                        '_validate_services_priced','_apply_coupon','_resolve_discount','_lock_checkout','_staff_resolve_client_ref',
                        '_staff_insert_completed_walkin_appt','decrement_product_stock','validate_coupon')
    order by p.proname;`)
  console.log(ev.split('\n').map((l) => '  ' + l).join('\n'))
  ok('EV RPCs públicas: secdef + search_path="" + grant authenticated',
    /staff_checkout\|secdef=true\|sp=search_path=""\|exec=authenticated/.test(ev)
    && /staff_checkout_get\|secdef=true\|sp=search_path=""\|exec=authenticated/.test(ev)
    && (ev.match(/staff_cart_\w+\|secdef=true\|sp=search_path=""\|exec=authenticated/g) || []).length === 3)
  ok('EV helpers internos: secdef + search_path="" + só owner',
    (ev.match(/(_validate_services_priced|_apply_coupon|_resolve_discount|_lock_checkout|_staff_resolve_client_ref|_staff_insert_completed_walkin_appt)\|secdef=true\|sp=search_path=""\|exec=owner/g) || []).length === 6)
  ok('EV decrement_product_stock: search_path="" + grant authenticated (revoke anon)',
    /decrement_product_stock\|secdef=true\|sp=search_path=""\|exec=authenticated/.test(ev))
  ok('EV validate_coupon: revoke anon (exec sem anon)', /validate_coupon\|secdef=true\|.*\|exec=(authenticated|authenticated,service_role)/.test(ev) && !/validate_coupon\|.*exec=[^|]*anon/.test(ev))
  const seqExec = psql(`select coalesce(string_agg(grantee,',' order by grantee),'(owner)') from information_schema.role_usage_grants where object_schema='public' and object_name='sales_nota_seq' and grantee in ('anon','authenticated','service_role');`)
  ok('EV sales_nota_seq: sem USAGE p/ anon/authenticated/service_role', seqExec === '(owner)' || seqExec === '', `[${seqExec}]`)
  const trunc = psql(`select coalesce(string_agg(distinct table_name,',' order by table_name),'-') from information_schema.role_table_grants where table_schema='public' and table_name in ('sales','sale_payments','cart_items','coupons','products','services') and grantee in ('anon','authenticated') and privilege_type in ('TRUNCATE','TRIGGER','REFERENCES');`)
  ok('EV higiene: sem TRUNCATE/TRIGGER/REFERENCES p/ anon/authenticated nas tabelas de venda', trunc === '-', `[${trunc}]`)

  const finalCount = psql(`select count(*)||' appts / '||(select count(*) from public.sales)||' sales' from public.appointments;`)
  console.log(`\n${fail === 0 ? '✅ TODOS OS TESTES PASSARAM' : '❌ HÁ FALHAS'} — ${pass} ok / ${fail} falhas   (${finalCount})\n`)
}

function limpar() {
  psql(`
    delete from public.notifications where recipient_client_id in (select id from auth.users where email like 'st2-%')
      or appt_id in (select id from public.appointments where client_name like 'st2-%');
    delete from public.sale_payments where barber_id in (select id from auth.users where email like 'st2-%');
    delete from public.sales where barber_id in (select id from auth.users where email like 'st2-%');
    delete from public.fiado_charges where barber_id in (select id from auth.users where email like 'st2-%');
    delete from public.staff_checkout_log where actor_id in (select id from auth.users where email like 'st2-%') or barber_id in (select id from auth.users where email like 'st2-%');
    delete from public.cash_closures where admin_id in (select id from auth.users where email like 'st2-%');
    delete from public.cart_items where appointment_id in (select id from public.appointments where client_name like 'st2-%')
      or barber_id in (select id from auth.users where email like 'st2-%');
    delete from public.appointments where client_name like 'st2-%'
      or barber_id in (select id from auth.users where email like 'st2-%')
      or client_id in (select id from auth.users where email like 'st2-%');
    delete from public.crm_clients where name like 'st2-%' or barber_id in (select id from auth.users where email like 'st2-%');
    delete from public.products where name like 'st2-%';
    delete from public.clients where id in (select id from auth.users where email like 'st2-%');
    delete from public.barbers where id in (select id from auth.users where email like 'st2-%');
    delete from auth.users where email like 'st2-%';`)
  const c = psql(`select count(*)||' appts / '||(select count(*) from public.sales)||' sales' from public.appointments;`)
  console.log(`(limpeza concluída — ${c}; sales_nota_seq permanece avançada — ids queimados são inofensivos)`)
}

try { await main() } catch (e) { console.error('\nERRO FATAL:', e.stack || e.message); fail++ }
finally { try { limpar() } catch (e) { console.error('limpeza falhou:', e.message) } }
process.exit(fail === 0 ? 0 : 1)
