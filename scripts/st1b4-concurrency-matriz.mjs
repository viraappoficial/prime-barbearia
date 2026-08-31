/**
 * ST-1b.4 · matriz de CONCORRÊNCIA das RPCs de escrita de staff — contra o LAB
 * (localhost:8100 / supabase-db).
 *
 * Prova a trava de linha introduzida por `20260831000400_staff_write_row_lock.sql`
 * (`_staff_appt_for_write_locked` — `SELECT … FOR UPDATE`) usada por:
 *   staff_reschedule_appointment / staff_accept_appointment /
 *   staff_start_appointment / staff_undo_start / staff_no_show /
 *   staff_cancel_appointment.
 *
 * - L : prova DETERMINÍSTICA do lock (S1 segura `FOR UPDATE` na linha; o helper
 *       NOVO bloqueia com `lock_timeout`, o VELHO retorna na hora).
 * - C : corridas REAIS (processos `psql` separados via `Promise.all`, cada caso
 *       em LOOP para expor corrida latente) — exatamente 1 vence, nunca 2
 *       agendamentos ativos de uma origem, nunca notificação dupla, e o perdedor
 *       recai num erro de domínio P0001 (jamais deadlock `40P01`).
 * - regressões de posse / papel / híbrido barbeiro+cliente sob o helper novo.
 *
 * Aplica as 5 migrations ST-1b.0–4 (idempotente) e deixa APLICADAS. Semeia
 * usuários/dados de teste e LIMPA no fim — o lab volta a 37 appointments (os 10
 * ativos backfillados pela ST-1b.0 permanecem com `duration`). Nunca toca
 * produção, `db push` nem o cutover.
 *
 * Uso: node scripts/st1b4-concurrency-matriz.mjs
 */
import { readFileSync } from 'node:fs'
import { execFileSync, spawn } from 'node:child_process'

const LAB = 'http://localhost:8100'
const MIG = new URL('../supabase/migrations/', import.meta.url)
const FILES = [
  '20260831000000_backfill_active_duration.sql',
  '20260831000100_staff_insert_appointment_core.sql',
  '20260831000200_staff_reschedule_appointment.sql',
  '20260831000300_staff_book_encaixe.sql',
  '20260831000400_staff_write_row_lock.sql',
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
const reloadPgrst = async () => { psql("notify pgrst, 'reload schema';"); await sleep(600) }

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
const PFX = `st1b4-${rid}`
let pass = 0, fail = 0
const ok = (n, c, extra = '') => {
  c ? pass++ : fail++
  console.log(`  ${c ? 'OK  ' : 'FAIL'} ${n}${extra ? `  — ${String(extra).replace(/\s+/g, ' ').slice(0, 170)}` : ''}`)
}
const ERR = (s) => (String(s).split('\n').find((l) => /ERROR|DETAIL/.test(l)) || String(s).slice(0, 120)).trim()
const DOMAIN = /NOT_RESCHEDULABLE|NOT_FOUND|NOT_STAFF|NOT_AUTH|NOT_ALLOWED|BAD_TRANSITION|ALREADY_STARTED|SLOT_TAKEN|OVERLAP_UNCHECKED|PAST_DAY|BAD_SLOT|BARBER_OFF/
const errOf = (m) => (String(m).match(DOMAIN) || [String(m).match(/permission denied|deadlock detected|40P01|55P03|57014/) || '?'])[0]
const noDeadlock = (m) => !/deadlock detected|40P01/.test(String(m))

// ── datas no fuso da loja ──
const TZ = '(select timezone from public.shop_settings where id = 1)'
const dateForDow = (dow, minAhead = 1) => psql(
  `select g::date::text from generate_series((now() at time zone ${TZ})::date + ${minAhead}, (now() at time zone ${TZ})::date + 20, interval '1 day') g
   where extract(dow from g) = ${dow} order by g limit 1;`)
// barbeiro A: espelha a loja, mas QUARTA (dow 3) de folga
const HOURS_A = '{"0":null,"1":["09:00","20:00"],"2":["09:00","20:00"],"3":null,"4":["09:00","20:00"],"5":["09:00","20:00"],"6":["09:00","18:00"]}'
let TUE, WED, THU

let CLI, CLI2, BARBA, BARBB, VEND, ADM, HYB
async function signup(tag) {
  const email = `${PFX}-${tag}@prime-lab.local`
  const r = await fetch(`${LAB}/auth/v1/signup`, { method: 'POST', headers: anonH, body: JSON.stringify({ email, password: 'Test-1234!' }) })
  const d = await r.json()
  if (!d.user?.id) throw new Error(`signup ${tag}: ${JSON.stringify(d)}`)
  return { uid: d.user.id, email }
}

function seedAppt({ barber, client = null, name, email = null, day, time, dur = 45, status = 'pendente', enc = false, services = "array['Corte Degradê']", started = false }) {
  return Number(psql(
    `insert into public.appointments (client_id, barber_id, services, day, day_label, time, duration, status, is_encaixe, iniciado_em, client_name, client_email)
     values (${client ? `'${client}'` : 'null'}, '${barber}', ${services}, date '${day}', 'x', '${time}', ${dur === null ? 'null' : dur},
             '${status}', ${enc}, ${started ? 'now()' : 'null'}, '${name}', ${email ? `'${email}'` : 'null'})
     returning id;`))
}
const apptCol = (id, c) => psql(`select coalesce(${c}::text,'<null>') from public.appointments where id = ${id};`)
// nº de agendamentos ATIVOS do barbeiro que herdam de p_id (mesmo cliente/serviços), excluindo o próprio p_id
const activeHeirs = (barber, clientId, exclude) => psql(
  `select count(*) from public.appointments
   where barber_id='${barber}' and ${clientId ? `client_id='${clientId}'` : 'client_id is null'}
     and status in ('pendente','confirmado') and client_name like '${PFX}%' and id <> ${exclude};`)
const notifCount = (apptId) => Number(psql(`select count(*) from public.notifications where appt_id = ${apptId};`))
const clearAll = (barber) => psql(
  `delete from public.notifications where appt_id in (select id from public.appointments where barber_id='${barber}' and client_name like '${PFX}%');
   delete from public.appointments where barber_id='${barber}' and client_name like '${PFX}%';`)

// ── RPC callers (via psql wrapper: begin; set role; …; commit;) ──
const rSQL = (id, day, time) => `select public.staff_reschedule_appointment(${id}, date '${day}', '${time}');`
const aSQL = (id) => `select public.staff_accept_appointment(${id});`
const sSQL = (id) => `select public.staff_start_appointment(${id});`
const uSQL = (id) => `select public.staff_undo_start(${id});`
const nSQL = (id) => `select public.staff_no_show(${id});`
const cSQL = (id, m = 'imprevisto') => `select public.staff_cancel_appointment(${id}, '${m}');`
const won = (arr) => arr.filter((x) => x.ok).length
const lostWith = (arr, rx) => arr.filter((x) => !x.ok && rx.test(x.err)).length
const noDeadlockAll = (arr) => arr.every((x) => x.ok || noDeadlock(x.err))

async function main() {
  console.log(`\n╔══ ST-1b.4 — matriz de concorrência (lab, prefixo ${PFX}) ══╗`)
  console.log('· aplicando ST-1b.0–4 (idempotente) ...')
  for (const f of FILES) psqlFile(new URL(f, MIG).pathname)
  await reloadPgrst()

  CLI = await signup('cli'); CLI2 = await signup('cli2')
  BARBA = await signup('barbA'); BARBB = await signup('barbB')
  VEND = await signup('vend'); ADM = await signup('adm'); HYB = await signup('hyb')
  psql(`insert into public.clients (id,email,name) values
    ('${CLI.uid}','${CLI.email}','${PFX} Cliente'),
    ('${CLI2.uid}','${CLI2.email}','${PFX} Cliente2'),
    ('${HYB.uid}','${HYB.email}','${PFX} Hyb');`)
  psql(`insert into public.barbers (id,name,email,role,is_barber,hours) values
    ('${BARBA.uid}','${PFX} BarbA','${BARBA.email}','barbeiro',true,'${HOURS_A}'),
    ('${BARBB.uid}','${PFX} BarbB','${BARBB.email}','barbeiro',true,null),
    ('${VEND.uid}','${PFX} Vend','${VEND.email}','vendas',false,null),
    ('${ADM.uid}','${PFX} Adm','${ADM.email}','admin',false,null),
    ('${HYB.uid}','${PFX} Hyb','${HYB.email}','barbeiro',true,null);`)
  TUE = dateForDow(2); WED = dateForDow(3); THU = dateForDow(4)
  console.log(`· seed ok — TUE=${TUE} (A atende)  WED=${WED} (A de folga)  THU=${THU} (A atende)\n`)

  // ══════════════ L — prova determinística do lock ══════════════
  console.log('── L — _staff_appt_for_write_locked realmente trava a linha ──')
  {
    const a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} L`, email: CLI.email, day: TUE, time: '10:30', status: 'confirmado' })
    // S1 segura FOR UPDATE na linha, sem commit
    const hold = spawn('docker', PSQL)
    let hErr = ''
    hold.stderr.on('data', (d) => { hErr += d })
    hold.stdin.write(`begin;\nselect id from public.appointments where id = ${a} for update;\n`)
    await sleep(400)

    // S2: chama o helper como owner (postgres) — os helpers têm EXECUTE revogado
    // de toda role externa; só as claims do JWT importam p/ auth.uid(). lock_timeout
    // curto → o helper NOVO deve BLOQUEAR no FOR UPDATE e ser cancelado.
    const probe = (fn) => {
      const sql = `set local lock_timeout = '800ms';\nset local request.jwt.claims to '{"sub":"${BARBA.uid}","role":"authenticated"}';\nselect public.${fn}(${a}, true);`
      try { execFileSync('docker', PSQL, { input: `begin;\n${sql}\ncommit;`, encoding: 'utf8' }); return { ok: true } }
      catch (e) { return { ok: false, err: ((e.stderr || '') + (e.stdout || '')).toString() } }
    }
    const t0 = Date.now()
    const rNew = probe('_staff_appt_for_write_locked')
    const dtNew = Date.now() - t0
    const t1 = Date.now()
    const rOld = probe('_staff_appt_for_write')
    const dtOld = Date.now() - t1

    hold.stdin.write('rollback;\n'); hold.stdin.end()
    await sleep(200)

    ok('L1 helper NOVO bloqueia na linha travada → lock_timeout (55P03), ~≥800ms',
      !rNew.ok && /lock timeout|canceling statement|55P03/i.test(rNew.err) && dtNew >= 700, `${dtNew}ms ${ERR(rNew.err)}`)
    ok('L2 helper VELHO (sem FOR UPDATE) retorna na hora mesmo com a linha travada',
      rOld.ok && dtOld < 500, `${dtOld}ms ok=${rOld.ok}`)
    clearAll(BARBA.uid)
  }

  // ══════════════ C1 — 2 remarcações do MESMO p_id p/ slots livres distintos ══════════════
  console.log('\n── C1 — remarcar ‖ remarcar (mesmo p_id) ──')
  {
    let doubles = 0, badLoser = 0, iters = 6
    for (let i = 0; i < iters; i++) {
      clearAll(BARBA.uid)
      const a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} c1-${i}`, email: CLI.email, day: TUE, time: '10:30', status: 'confirmado' })
      const res = await Promise.all([
        callAsP(BARBA.uid, rSQL(a, TUE, '15:00')),
        callAsP(BARBA.uid, rSQL(a, TUE, '16:30')),
      ])
      const heirs = Number(activeHeirs(BARBA.uid, CLI.uid, a))
      if (heirs !== 1) doubles++
      if (won(res) !== 1) doubles++
      if (lostWith(res, /NOT_RESCHEDULABLE/) !== 1) badLoser++
      if (apptCol(a, 'status') !== 'cancelado') doubles++
      if (!noDeadlockAll(res)) doubles++
    }
    ok(`C1 ${iters}× remarcar‖remarcar mesmo p_id (slots livres distintos) → sempre 1 vence, 1 herdeiro ativo, antigo cancelado`, doubles === 0, `doubles=${doubles}`)
    ok('C1 perdedor sempre cai em NOT_RESCHEDULABLE (nunca deadlock)', badLoser === 0, `badLoser=${badLoser}`)
    clearAll(BARBA.uid)
  }

  // ══════════════ C1b — MESMO p_id p/ DIAS distintos (advisory lock não serializa) ══════════════
  console.log('\n── C1b — remarcar ‖ remarcar (mesmo p_id, dias distintos) ──')
  {
    let bad = 0, iters = 6
    for (let i = 0; i < iters; i++) {
      clearAll(BARBA.uid)
      const a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} c1b-${i}`, email: CLI.email, day: TUE, time: '10:30', status: 'confirmado' })
      const res = await Promise.all([
        callAsP(BARBA.uid, rSQL(a, TUE, '15:00')),
        callAsP(BARBA.uid, rSQL(a, THU, '15:00')),
      ])
      const heirs = Number(activeHeirs(BARBA.uid, CLI.uid, a))
      if (heirs !== 1 || won(res) !== 1 || apptCol(a, 'status') !== 'cancelado' || !noDeadlockAll(res)) bad++
    }
    ok(`C1b ${iters}× remarcar p/ dias distintos → o FOR UPDATE (não o advisory) garante 1 herdeiro`, bad === 0, `bad=${bad}`)
    clearAll(BARBA.uid)
  }

  // ══════════════ C1c — MESMO p_id p/ o MESMO slot livre ══════════════
  console.log('\n── C1c — remarcar ‖ remarcar (mesmo p_id, mesmo slot) ──')
  {
    let bad = 0, iters = 5
    for (let i = 0; i < iters; i++) {
      clearAll(BARBA.uid)
      const a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} c1c-${i}`, email: CLI.email, day: TUE, time: '10:30', status: 'confirmado' })
      const res = await Promise.all([
        callAsP(BARBA.uid, rSQL(a, TUE, '15:00')),
        callAsP(BARBA.uid, rSQL(a, TUE, '15:00')),
      ])
      // perdedor: bloqueado no FOR UPDATE → relê cancelado → NOT_RESCHEDULABLE
      // (nunca chega a SLOT_TAKEN, que era o antigo comportamento p/ mesmo slot)
      if (won(res) !== 1 || lostWith(res, /NOT_RESCHEDULABLE/) !== 1 || Number(activeHeirs(BARBA.uid, CLI.uid, a)) !== 1 || !noDeadlockAll(res)) bad++
    }
    ok(`C1c ${iters}× remarcar p/ o mesmo slot → 1 vence, perdedor NOT_RESCHEDULABLE, 1 herdeiro`, bad === 0, `bad=${bad}`)
    clearAll(BARBA.uid)
  }

  // ══════════════ C2 — remarcar ‖ aceitar (mesmo p_id) ══════════════
  console.log('\n── C2 — remarcar ‖ aceitar (mesmo p_id) ──')
  {
    let bad = 0, iters = 8
    for (let i = 0; i < iters; i++) {
      clearAll(BARBA.uid)
      const a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} c2-${i}`, email: CLI.email, day: TUE, time: '10:30', status: 'pendente' })
      const res = await Promise.all([
        callAsP(BARBA.uid, rSQL(a, TUE, '15:00')),
        callAsP(BARBA.uid, aSQL(a)),
      ])
      const [rResched, rAccept] = res
      const heirs = Number(activeHeirs(BARBA.uid, CLI.uid, a))
      const st = apptCol(a, 'status')
      let okCase
      if (rResched.ok) {
        // remarcar venceu (ou rodou após o accept): antigo cancelado, 1 herdeiro.
        // accept pode ter vencido antes (status herdado 'confirmado') ou perdido (BAD_TRANSITION).
        okCase = st === 'cancelado' && heirs === 1 &&
          (rAccept.ok || /BAD_TRANSITION/.test(rAccept.err))
      } else {
        // remarcar perdeu → accept venceu: A confirmado, sem herdeiro, remarcar = NOT_RESCHEDULABLE
        okCase = /NOT_RESCHEDULABLE/.test(rResched.err) && rAccept.ok && st === 'confirmado' && heirs === 0
      }
      if (!okCase || !noDeadlockAll(res)) bad++
    }
    ok(`C2 ${iters}× remarcar‖aceitar → nunca 2 herdeiros; perdedor num P0001 coerente`, bad === 0, `bad=${bad}`)
    clearAll(BARBA.uid)
  }

  // ══════════════ C3 — remarcar ‖ cancelar (mesmo p_id) ══════════════
  console.log('\n── C3 — remarcar ‖ cancelar (mesmo p_id) ──')
  {
    let bad = 0, iters = 8
    for (let i = 0; i < iters; i++) {
      clearAll(BARBA.uid)
      const a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} c3-${i}`, email: CLI.email, day: TUE, time: '10:30', status: 'confirmado' })
      const res = await Promise.all([
        callAsP(BARBA.uid, rSQL(a, TUE, '15:00')),
        callAsP(BARBA.uid, cSQL(a)),
      ])
      const [rResched, rCancel] = res
      const heirs = Number(activeHeirs(BARBA.uid, CLI.uid, a))
      // A sempre termina cancelado (ambos os caminhos cancelam p_id)
      let okCase = apptCol(a, 'status') === 'cancelado' && won(res) >= 1
      if (rResched.ok) {
        // remarcar venceu: 1 herdeiro; cancel perdeu → BAD_TRANSITION; notif do herdeiro = 1 'remarcado'
        okCase = okCase && heirs === 1 && !rCancel.ok && /BAD_TRANSITION/.test(rCancel.err)
      } else {
        // cancelar venceu: 0 herdeiro; remarcar = NOT_RESCHEDULABLE; 1 notif 'cancelado-barbeiro' em A
        okCase = okCase && heirs === 0 && /NOT_RESCHEDULABLE/.test(rResched.err) && notifCount(a) === 1
      }
      if (!okCase || !noDeadlockAll(res)) bad++
    }
    ok(`C3 ${iters}× remarcar‖cancelar → A cancelado, sem herdeiro-duplo, sem notif dupla`, bad === 0, `bad=${bad}`)
    clearAll(BARBA.uid)
  }

  // ══════════════ C4 — aceitar ‖ aceitar (mesmo p_id) ══════════════
  console.log('\n── C4 — aceitar ‖ aceitar (mesmo p_id) ──')
  {
    let bad = 0, iters = 8
    for (let i = 0; i < iters; i++) {
      clearAll(BARBA.uid)
      const a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} c4-${i}`, email: CLI.email, day: TUE, time: '10:30', status: 'pendente' })
      const res = await Promise.all([callAsP(BARBA.uid, aSQL(a)), callAsP(BARBA.uid, aSQL(a))])
      const nConf = Number(psql(`select count(*) from public.notifications where appt_id=${a} and type='confirmado';`))
      if (won(res) !== 1 || lostWith(res, /BAD_TRANSITION/) !== 1 || apptCol(a, 'status') !== 'confirmado' || nConf !== 1 || !noDeadlockAll(res)) bad++
    }
    ok(`C4 ${iters}× aceitar‖aceitar → 1 confirma, 1 BAD_TRANSITION, EXATAMENTE 1 notificação`, bad === 0, `bad=${bad}`)
    clearAll(BARBA.uid)
  }

  // ══════════════ C5 — iniciar ‖ iniciar (mesmo p_id) ══════════════
  console.log('\n── C5 — iniciar ‖ iniciar (mesmo p_id) ──')
  {
    let bad = 0, iters = 8
    for (let i = 0; i < iters; i++) {
      clearAll(BARBA.uid)
      const a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} c5-${i}`, email: CLI.email, day: TUE, time: '10:30', status: 'confirmado' })
      const res = await Promise.all([callAsP(BARBA.uid, sSQL(a)), callAsP(BARBA.uid, sSQL(a))])
      if (won(res) !== 1 || lostWith(res, /ALREADY_STARTED/) !== 1 || apptCol(a, 'iniciado_em') === '<null>' || !noDeadlockAll(res)) bad++
    }
    ok(`C5 ${iters}× iniciar‖iniciar → 1 inicia, 1 ALREADY_STARTED (não sobrescreve iniciado_em)`, bad === 0, `bad=${bad}`)
    clearAll(BARBA.uid)
  }

  // ══════════════ C6 — desfazer início ‖ desfazer início ══════════════
  console.log('\n── C6 — desfazer início ‖ desfazer início ──')
  {
    let bad = 0, iters = 6
    for (let i = 0; i < iters; i++) {
      clearAll(BARBA.uid)
      const a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} c6-${i}`, email: CLI.email, day: TUE, time: '10:30', status: 'confirmado', started: true })
      const res = await Promise.all([callAsP(BARBA.uid, uSQL(a)), callAsP(BARBA.uid, uSQL(a))])
      if (won(res) !== 1 || lostWith(res, /BAD_TRANSITION/) !== 1 || apptCol(a, 'iniciado_em') !== '<null>' || !noDeadlockAll(res)) bad++
    }
    ok(`C6 ${iters}× desfazer‖desfazer → 1 desfaz, 1 BAD_TRANSITION`, bad === 0, `bad=${bad}`)
    clearAll(BARBA.uid)
  }

  // ══════════════ C7 — não compareceu ‖ cancelar (cross-op) ══════════════
  console.log('\n── C7 — não compareceu ‖ cancelar (mesmo p_id) ──')
  {
    let bad = 0, iters = 8
    for (let i = 0; i < iters; i++) {
      clearAll(BARBA.uid)
      const a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} c7-${i}`, email: CLI.email, day: TUE, time: '10:30', status: 'confirmado' })
      const res = await Promise.all([callAsP(BARBA.uid, nSQL(a)), callAsP(BARBA.uid, cSQL(a))])
      const st = apptCol(a, 'status')
      const nNotif = notifCount(a)
      // 1 vence (nao_compareceu OU cancelado), o outro → BAD_TRANSITION; no_show não notifica, cancel sim → ≤1 notif
      const okCase = won(res) === 1 && lostWith(res, /BAD_TRANSITION/) === 1 &&
        (st === 'nao_compareceu' || st === 'cancelado') && nNotif <= 1
      if (!okCase || !noDeadlockAll(res)) bad++
    }
    ok(`C7 ${iters}× no_show‖cancelar → 1 vence, 1 BAD_TRANSITION, ≤1 notif, status coerente`, bad === 0, `bad=${bad}`)
    clearAll(BARBA.uid)
  }

  // ══════════════ C8 — regressão de POSSE sob o helper travado ══════════════
  console.log('\n── C8/C9/C10 — posse / papel / híbrido sob _staff_appt_for_write_locked ──')
  {
    // C8 barbeiro B remarca linha de A → NOT_FOUND (não vaza posse)
    let a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} c8`, email: CLI.email, day: TUE, time: '10:30', status: 'confirmado' })
    let r = tryCallAs(BARBB.uid, rSQL(a, TUE, '15:00'))
    ok('C8 barbeiro B remarca linha de A → NOT_FOUND, A intacto', !r.ok && /NOT_FOUND/.test(r.err) && apptCol(a, 'status') === 'confirmado', errOf(r.err))
    r = tryCallAs(BARBB.uid, aSQL(a))
    ok('C8 barbeiro B aceita linha de A → NOT_FOUND', !r.ok && /NOT_FOUND/.test(r.err), errOf(r.err))
    clearAll(BARBA.uid)

    // C9 papel
    a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} c9`, email: CLI.email, day: TUE, time: '10:30', status: 'confirmado' })
    r = tryCallAs(CLI.uid, rSQL(a, TUE, '15:00'))
    ok('C9 cliente chama staff_reschedule → NOT_STAFF', !r.ok && /NOT_STAFF/.test(r.err), errOf(r.err))
    r = tryCallAs(null, rSQL(a, TUE, '15:00'))
    ok('C9 anon chama staff_reschedule → permission denied', !r.ok && /permission denied|NOT_AUTH|42501/.test(r.err), ERR(r.err))
    r = tryCallAs(VEND.uid, cSQL(a))
    ok('C9 vendas chama staff_cancel → NOT_FOUND (D4: helper travado passa false)', !r.ok && /NOT_FOUND/.test(r.err), errOf(r.err))
    r = tryCallAs(VEND.uid, rSQL(a, TUE, '15:00'))
    ok('C9 vendas chama staff_reschedule → OK (D-1b-1)', r.ok, r.ok ? 'ok' : errOf(r.err))
    clearAll(BARBA.uid)

    // C10 híbrido barbeiro+cliente: remarca a própria linha-COMO-CLIENTE (barbeiro é B) → NOT_FOUND
    a = seedAppt({ barber: BARBB.uid, client: HYB.uid, name: `${PFX} c10`, email: HYB.email, day: TUE, time: '10:30', status: 'pendente' })
    r = tryCallAs(HYB.uid, rSQL(a, TUE, '15:00'))
    ok('C10 híbrido remarca a própria linha-como-cliente via staff_reschedule → NOT_FOUND', !r.ok && /NOT_FOUND/.test(r.err) && apptCol(a, 'status') === 'pendente', errOf(r.err))
    // e a corrida: híbrido (como cliente) ‖ barbeiro B dono aceitando — dono vence, híbrido NOT_FOUND
    const res = await Promise.all([callAsP(HYB.uid, rSQL(a, TUE, '15:00')), callAsP(BARBB.uid, aSQL(a))])
    ok('C10 corrida híbrido-como-cliente ‖ dono-B → dono aceita, híbrido NOT_FOUND, 0 herdeiro',
      res[1].ok && !res[0].ok && /NOT_FOUND/.test(res[0].err) && Number(activeHeirs(BARBB.uid, HYB.uid, a)) === 0 && noDeadlockAll(res), `dono=${res[1].ok} hib=${errOf(res[0].err)}`)
    clearAll(BARBB.uid)
  }

  // ══════════════ C11 — regressão sequencial (o lock não quebrou o caminho normal) ══════════════
  console.log('\n── C11 — caminho normal (sequencial) intacto ──')
  {
    clearAll(BARBA.uid)
    let a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} c11`, email: CLI.email, day: TUE, time: '10:30', status: 'confirmado' })
    let r = tryCallAs(BARBA.uid, rSQL(a, TUE, '15:00'))
    const nid = r.ok ? Number((r.out.match(/\d+/) || [])[0]) : null
    ok('C11 remarcar normal → novo id, antigo cancelado, status preservado', r.ok && nid > 0 && apptCol(a, 'status') === 'cancelado' && apptCol(nid, 'status') === 'confirmado', r.ok ? `#${a}→#${nid}` : errOf(r.err))
    clearAll(BARBA.uid)

    a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} c11b`, email: CLI.email, day: TUE, time: '10:30', status: 'pendente' })
    r = tryCallAs(BARBA.uid, aSQL(a)); const ok1 = r.ok
    r = tryCallAs(BARBA.uid, aSQL(a)) // 2ª vez sequencial → BAD_TRANSITION
    ok('C11 aceitar 2× sequencial → 1ª ok, 2ª BAD_TRANSITION, 1 notif', ok1 && !r.ok && /BAD_TRANSITION/.test(r.err) && notifCount(a) === 1, errOf(r.err))
    clearAll(BARBA.uid)

    a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} c11c`, email: CLI.email, day: TUE, time: '10:30', status: 'confirmado' })
    tryCallAs(BARBA.uid, sSQL(a))
    r = tryCallAs(BARBA.uid, sSQL(a))
    ok('C11 iniciar 2× sequencial → 2ª ALREADY_STARTED', !r.ok && /ALREADY_STARTED/.test(r.err), errOf(r.err))
    clearAll(BARBA.uid)
  }

  // ══════════════ evidências ══════════════
  console.log('\n── evidências: helper novo/velho + RPCs ──')
  const ev = psql(`select p.proname||' | secdef='||p.prosecdef||' | '||coalesce(array_to_string(p.proconfig,','),'-')||' | vol='||p.provolatile::text||' | exec='||
      coalesce((select string_agg(g.rolname,',' order by g.rolname) from aclexplode(p.proacl) a join pg_roles g on g.oid=a.grantee
        where a.privilege_type='EXECUTE' and g.rolname not in ('postgres','supabase_admin')),'(só owner)')
    from pg_proc p where p.pronamespace='public'::regnamespace
      and p.proname in ('_staff_appt_for_write','_staff_appt_for_write_locked','staff_reschedule_appointment','staff_accept_appointment','staff_start_appointment','staff_undo_start','staff_no_show','staff_cancel_appointment')
    order by p.proname;`)
  console.log(ev.split('\n').map((l) => '  ' + l).join('\n'))
  const evLocked = /_staff_appt_for_write_locked \| secdef=true \| search_path="" \| vol=v \| exec=\(só owner\)/.test(ev)
  const evOld = /_staff_appt_for_write \| secdef=true \| search_path="" \| vol=s \| exec=\(só owner\)/.test(ev)
  const evRpcs = (ev.match(/staff_\w+ \| secdef=true \| search_path="" \| vol=v \| exec=authenticated/g) || []).length === 6
  const bodies = psql(`select count(*) from pg_proc p where p.pronamespace='public'::regnamespace
    and p.proname in ('staff_reschedule_appointment','staff_accept_appointment','staff_start_appointment','staff_undo_start','staff_no_show','staff_cancel_appointment')
    and pg_get_functiondef(p.oid) like '%_staff_appt_for_write_locked%';`)
  const forUpd = psql(`select (position('for update' in lower(pg_get_functiondef(p.oid))) > 0)::text from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='_staff_appt_for_write_locked';`)
  ok('EV helper novo: volatile + secdef + search_path="" + só owner', evLocked, '')
  ok('EV helper velho: mantido stable + secdef + search_path="" + só owner (inerte)', evOld, '')
  ok('EV 6 RPCs: secdef + search_path="" + volatile + grant só authenticated', evRpcs, '')
  ok('EV 6 RPCs chamam _staff_appt_for_write_locked', bodies === '6', `${bodies}/6`)
  ok('EV _staff_appt_for_write_locked contém SELECT … FOR UPDATE', forUpd === 'true', forUpd)

  const finalCount = psql(`select count(*) from public.appointments;`)
  console.log(`\n${fail === 0 ? '✅ TODOS OS TESTES PASSARAM' : '❌ HÁ FALHAS'} — ${pass} ok / ${fail} falhas   (appointments no lab: ${finalCount})\n`)
}

function limpar() {
  // varre a FAMÍLIA 'st1b4-%' (não só este rid) — um run morto por SIGTERM se
  // auto-cura no próximo. Nunca toca linha sem o prefixo.
  psql(`
    delete from public.notifications where appt_id in (select id from public.appointments where client_name like 'st1b4-%')
      or recipient_client_id in (select id from auth.users where email like 'st1b4-%');
    delete from public.appointments where client_name like 'st1b4-%'
      or client_id in (select id from auth.users where email like 'st1b4-%')
      or barber_id in (select id from auth.users where email like 'st1b4-%');
    delete from public.crm_clients where barber_id in (select id from auth.users where email like 'st1b4-%') or name like 'st1b4-%';
    delete from public.clients where id in (select id from auth.users where email like 'st1b4-%');
    delete from public.barbers where id in (select id from auth.users where email like 'st1b4-%');
    delete from auth.users where email like 'st1b4-%';`)
  const c = psql(`select count(*) from public.appointments;`)
  console.log(`(limpeza concluída — appointments no lab: ${c}; os 10 ativos backfillados pela ST-1b.0 permanecem)`)
}

try { await main() } catch (e) { console.error('\nERRO FATAL:', e.stack || e.message); fail++ }
finally { try { limpar() } catch (e) { console.error('limpeza falhou:', e.message) } }
process.exit(fail === 0 ? 0 : 1)
