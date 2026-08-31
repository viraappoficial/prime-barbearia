/**
 * ST-1b.5 · matriz do PROTOCOLO CANÔNICO DE LOCK DE AGENDA — corridas cross-
 * surface cliente × staff, contra o LAB (localhost:8100 / supabase-db).
 *
 * Prova `20260831000500_agenda_lock_protocol.sql`:
 *   - `_lock_agenda(barber, day)` — chave canônica única, sem grant externo,
 *     reutilizada por `_insert_appointment` (cliente) e `_staff_insert_appointment`
 *     (staff);
 *   - protocolo (a) authz mínima sem lock → (b) lock da agenda de destino →
 *     (c) releitura da linha `FOR UPDATE` revalidada → (d) escrita, em
 *     `reschedule_appointment` (cliente) e `staff_reschedule_appointment` (staff).
 *     NUNCA linha → agenda.
 *
 * - X0  evidências (pg_proc + cores chamam o helper + chave canônica).
 * - X1  prova DETERMINÍSTICA da chave: S1 segura `_lock_agenda`; book do
 *       cliente e encaixe do staff BLOQUEIAM (mesma chave); a chave CRUA antiga
 *       do cliente NÃO bloqueia.
 * - X1b prova por `pg_locks` que a chave advisory == hashtextextended('agenda|…').
 * - X2  cliente book × staff encaixe no mesmo slot → exatamente 1 vence.
 * - X3  cliente book × staff remarcar p/ o mesmo slot → 1 vence; se a remarca
 *       falhar, o antigo permanece ativo.
 * - X4  cliente remarcar × staff remarcar o mesmo p_id → sem deadlock, 1 herdeiro.
 * - X5  cliente remarcar × cliente remarcar o mesmo p_id → sem deadlock, 1 herdeiro.
 * - X4/X5 repetidos em DIAS distintos.
 * - X6  prova DETERMINÍSTICA de que o lock de agenda vem ANTES da linha (sem
 *       inversão): com a agenda travada, os dois reschedules bloqueiam sem
 *       tocar a linha.
 * - X7  caminho normal (sequencial) intacto + erros de domínio preservados.
 * - zero `40P01` em TODAS as corridas.
 *
 * Aplica ST-1b.0–5 (idempotente) e deixa APLICADAS. Semeia usuários/dados e
 * LIMPA no fim — lab volta a 37 appointments. Nunca toca produção / db push /
 * cutover.
 *
 * Uso: node scripts/st1b5-agenda-lock-matriz.mjs
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
  '20260831000500_agenda_lock_protocol.sql',
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
const PFX = `st1b5-${rid}`
let pass = 0, fail = 0
const ok = (n, c, extra = '') => {
  c ? pass++ : fail++
  console.log(`  ${c ? 'OK  ' : 'FAIL'} ${n}${extra ? `  — ${String(extra).replace(/\s+/g, ' ').slice(0, 180)}` : ''}`)
}
const ERR = (s) => (String(s).split('\n').find((l) => /ERROR|DETAIL/.test(l)) || String(s).slice(0, 120)).trim()
const DOMAIN = /NOT_RESCHEDULABLE|NOT_FOUND|NOT_STAFF|NOT_AUTH|NOT_AUTHENTICATED|NOT_ALLOWED|BAD_TRANSITION|SLOT_TAKEN|OVERLAP_UNCHECKED|PAST_DAY|BAD_SLOT|BARBER_OFF|STAFF_NOT_ALLOWED/
const errOf = (m) => (String(m).match(DOMAIN) || [String(m).match(/permission denied|deadlock detected|40P01|55P03|57014/) || '?'])[0]
const noDeadlock = (m) => !/deadlock detected|40P01/.test(String(m))
const noDeadlockAll = (arr) => arr.every((x) => x.ok || noDeadlock(x.err))
const won = (arr) => arr.filter((x) => x.ok).length

const SVC45 = 2 // Corte Degradê 45min
const TZ = '(select timezone from public.shop_settings where id = 1)'
const dateForDow = (dow) => psql(
  `select g::date::text from generate_series((now() at time zone ${TZ})::date + 1, (now() at time zone ${TZ})::date + 9, interval '1 day') g
   where extract(dow from g) = ${dow} order by g limit 1;`)
let TUE, THU
const ONTEM = psql(`select ((now() at time zone ${TZ})::date - 1)::text;`)

let CLI, CLI2, BSTAFF, ADM
async function signup(tag) {
  const email = `${PFX}-${tag}@prime-lab.local`
  const r = await fetch(`${LAB}/auth/v1/signup`, { method: 'POST', headers: anonH, body: JSON.stringify({ email, password: 'Test-1234!' }) })
  const d = await r.json()
  if (!d.user?.id) throw new Error(`signup ${tag}: ${JSON.stringify(d)}`)
  return { uid: d.user.id, email }
}

// seed appt como owner (igual staff legado). duração explícita.
const seedAppt = ({ barber, client = null, name, email = null, day, time, dur = 45, status = 'pendente' }) =>
  Number(psql(
    `insert into public.appointments (client_id, barber_id, services, day, day_label, time, duration, status, is_encaixe, client_name, client_email)
     values (${client ? `'${client}'` : 'null'}, '${barber}', array['Corte Degradê'], date '${day}', 'x', '${time}', ${dur},
             '${status}', false, '${name}', ${email ? `'${email}'` : 'null'}) returning id;`))
const apptCol = (id, c) => psql(`select coalesce(${c}::text,'<null>') from public.appointments where id = ${id};`)
const activeAt = (barber, day, time) => Number(psql(
  `select count(*) from public.appointments where barber_id='${barber}' and day=date '${day}' and time='${time}' and status in ('pendente','confirmado') and client_name like '${PFX}%';`))
const activeHeirs = (barber, clientId, exclude) => Number(psql(
  `select count(*) from public.appointments where barber_id='${barber}' and client_id='${clientId}'
     and status in ('pendente','confirmado') and client_name like '${PFX}%' and id <> ${exclude};`))
const clearAll = () => psql(
  `delete from public.notifications where appt_id in (select id from public.appointments where client_name like '${PFX}%');
   delete from public.appointments where client_name like '${PFX}%';`)

const book = (uid, barber, day, time) => `select public.book_appointment('${barber}', date '${day}', '${time}', array[${SVC45}]::bigint[]);`
const cliResched = (uid, id, barber, day, time) => `select public.reschedule_appointment(${id}, '${barber}', date '${day}', '${time}', array[${SVC45}]::bigint[]);`
const staffResched = (id, day, time) => `select public.staff_reschedule_appointment(${id}, date '${day}', '${time}');`
const encaixe = (barber, refUid, day, time) =>
  `select public.staff_book_encaixe('${barber}', jsonb_build_object('mode','account','id','${refUid}'), date '${day}', '${time}', array[${SVC45}]::bigint[], null, false);`

async function main() {
  console.log(`\n╔══ ST-1b.5 — protocolo canônico de lock de agenda (lab, ${PFX}) ══╗`)
  console.log('· aplicando ST-1b.0–5 (idempotente) ...')
  for (const f of FILES) psqlFile(new URL(f, MIG).pathname)
  await reloadPgrst()

  CLI = await signup('cli'); CLI2 = await signup('cli2')
  BSTAFF = await signup('barb'); ADM = await signup('adm')
  psql(`insert into public.clients (id,email,name) values
    ('${CLI.uid}','${CLI.email}','${PFX} Cliente'),
    ('${CLI2.uid}','${CLI2.email}','${PFX} Cliente2');`)
  psql(`insert into public.barbers (id,name,email,role,is_barber,hours) values
    ('${BSTAFF.uid}','${PFX} Barb','${BSTAFF.email}','barbeiro',true,null),
    ('${ADM.uid}','${PFX} Adm','${ADM.email}','admin',false,null);`)
  TUE = dateForDow(2); THU = dateForDow(4)
  console.log(`· seed ok — CLI/CLI2 contas · BSTAFF barbeiro (hours null) · TUE=${TUE}  THU=${THU}\n`)

  // ══════════════ X0 — evidências ══════════════
  console.log('── X0 — evidências ──')
  const ev = psql(`select p.proname||'|secdef='||p.prosecdef||'|'||coalesce(array_to_string(p.proconfig,','),'-')||'|vol='||p.provolatile::text||'|exec='||
      coalesce((select string_agg(g.rolname,',' order by g.rolname) from aclexplode(p.proacl) a join pg_roles g on g.oid=a.grantee
        where a.privilege_type='EXECUTE' and g.rolname not in ('postgres','supabase_admin')),'owner')
    from pg_proc p where p.pronamespace='public'::regnamespace
      and p.proname in ('_lock_agenda','_insert_appointment','_staff_insert_appointment','reschedule_appointment','staff_reschedule_appointment','book_appointment','staff_book_encaixe')
    order by p.proname;`)
  console.log(ev.split('\n').map((l) => '  ' + l).join('\n'))
  ok('X0 _lock_agenda: volatile + secdef + search_path="" + só owner',
    /_lock_agenda\|secdef=true\|search_path=""\|vol=v\|exec=owner/.test(ev))
  ok('X0 book_appointment / reschedule_appointment / staff_reschedule_appointment: grant só authenticated',
    /book_appointment\|secdef=true\|search_path=""\|vol=v\|exec=authenticated/.test(ev) &&
    /reschedule_appointment\|secdef=true\|search_path=""\|vol=v\|exec=authenticated/.test(ev) &&
    /staff_reschedule_appointment\|secdef=true\|search_path=""\|vol=v\|exec=authenticated/.test(ev))
  const coresLock = psql(`select count(*) from pg_proc where pronamespace='public'::regnamespace
    and proname in ('_insert_appointment','_staff_insert_appointment') and pg_get_functiondef(oid) like '%public._lock_agenda(%';`)
  ok('X0 os DOIS núcleos (cliente + staff) chamam public._lock_agenda', coresLock === '2', `${coresLock}/2`)
  const cruaAntiga = psql(`select coalesce(string_agg(proname,','),'(nenhuma)') from pg_proc where pronamespace='public'::regnamespace
    and pg_get_functiondef(oid) ~ 'hashtextextended\\(\\s*p_barber_id::text';`)
  ok('X0 nenhuma função ainda usa a chave crua barber||day', cruaAntiga === '(nenhuma)', cruaAntiga)
  const protoOrder = psql(`select count(*) from pg_proc where pronamespace='public'::regnamespace
    and proname in ('reschedule_appointment','staff_reschedule_appointment')
    and position('_lock_agenda' in pg_get_functiondef(oid)) < position('for update' in lower(pg_get_functiondef(oid)));`)
  ok('X0 os 2 reschedules: _lock_agenda ANTES do FOR UPDATE (protocolo a→b→c)', protoOrder === '2', `${protoOrder}/2`)

  // ══════════════ X1 — prova determinística: chave canônica idêntica ══════════════
  console.log('\n── X1 — chave canônica: book do cliente e encaixe do staff bloqueiam na MESMA chave ──')
  {
    const hold = spawn('docker', PSQL)
    hold.stdin.write(`begin;\nselect public._lock_agenda('${BSTAFF.uid}', date '${TUE}');\n`)
    await sleep(400)

    // pg_try_advisory nas duas chaves, de outra sessão
    const tryKey = (expr) => psql(`select pg_try_advisory_xact_lock(${expr})::text;`) // sessão nova → xact fecha na hora
    const canon = tryKey(`hashtextextended('agenda|' || '${BSTAFF.uid}' || '|' || '${TUE}', 0)`)
    const crua = tryKey(`hashtextextended('${BSTAFF.uid}' || '|' || '${TUE}', 0)`)
    ok('X1 chave CANÔNICA está tomada por S1 (pg_try_advisory → false)', canon === 'false', `try=${canon}`)
    ok('X1 chave CRUA antiga do cliente NÃO está tomada (lock diferente)', crua === 'true', `try=${crua}`)

    // book do cliente com lock_timeout curto → deve bloquear na canônica
    const probe = (uid, sql) => {
      try {
        execFileSync('docker', PSQL, { input:
          `begin;\nset local lock_timeout='800ms';\nset local role authenticated;\nset local request.jwt.claims to '{"sub":"${uid}","role":"authenticated"}';\n${sql}\ncommit;`,
          encoding: 'utf8' })
        return { ok: true }
      } catch (e) { return { ok: false, err: ((e.stderr || '') + (e.stdout || '')).toString() } }
    }
    const t0 = Date.now(); const rb = probe(CLI.uid, book(CLI.uid, BSTAFF.uid, TUE, '15:00')); const dtb = Date.now() - t0
    const t1 = Date.now(); const re = probe(BSTAFF.uid, encaixe(BSTAFF.uid, CLI.uid, TUE, '16:30')); const dte = Date.now() - t1

    hold.stdin.write('rollback;\n'); hold.stdin.end()
    await sleep(200)

    ok('X1 book_appointment (cliente) BLOQUEIA na agenda travada → lock timeout ~≥800ms',
      !rb.ok && /lock timeout|canceling statement|55P03/i.test(rb.err) && dtb >= 700, `${dtb}ms ${ERR(rb.err)}`)
    ok('X1 staff_book_encaixe (staff) BLOQUEIA na MESMA chave → lock timeout ~≥800ms',
      !re.ok && /lock timeout|canceling statement|55P03/i.test(re.err) && dte >= 700, `${dte}ms ${ERR(re.err)}`)
    clearAll()
  }

  // ══════════════ X1b — pg_locks: a chave é hashtextextended('agenda|…') ══════════════
  console.log('\n── X1b — pg_locks confirma a chave canônica ──')
  {
    const hold = spawn('docker', PSQL)
    hold.stdin.write(`begin;\nselect public._lock_agenda('${BSTAFF.uid}', date '${THU}');\n`)
    await sleep(400)
    const match = psql(`
      with k as (select hashtextextended('agenda|' || '${BSTAFF.uid}' || '|' || '${THU}', 0) as key)
      select exists(
        select 1 from pg_locks l, k
        where l.locktype='advisory' and l.objsubid=1
          and l.classid::bigint = ((k.key >> 32) & 4294967295)
          and l.objid::bigint   = (k.key & 4294967295)
      )::text;`)
    hold.stdin.write('rollback;\n'); hold.stdin.end()
    await sleep(200)
    ok('X1b pg_locks tem um advisory lock com objid/classid == hashtextextended(\'agenda|<barber>|<dia>\')', match === 'true', `match=${match}`)
  }

  // ══════════════ X2 — cliente book × staff encaixe no mesmo slot ══════════════
  console.log('\n── X2 — cliente book ‖ staff encaixe (mesmo slot) ──')
  {
    let bad = 0, iters = 8
    for (let i = 0; i < iters; i++) {
      clearAll()
      const res = await Promise.all([
        callAsP(CLI.uid, book(CLI.uid, BSTAFF.uid, TUE, '13:30')),
        callAsP(BSTAFF.uid, encaixe(BSTAFF.uid, CLI2.uid, TUE, '13:30')),
      ])
      const rows = activeAt(BSTAFF.uid, TUE, '13:30')
      if (won(res) !== 1 || rows !== 1 || res.filter((x) => !x.ok && /SLOT_TAKEN/.test(x.err)).length !== 1 || !noDeadlockAll(res)) bad++
    }
    ok(`X2 ${iters}× book‖encaixe mesmo slot → exatamente 1 vence, 1 linha ativa, 1 SLOT_TAKEN, 0 deadlock`, bad === 0, `bad=${bad}`)
    clearAll()
  }

  // ══════════════ X3 — cliente book × staff remarcar p/ o mesmo slot ══════════════
  console.log('\n── X3 — cliente book ‖ staff remarcar (p/ o mesmo slot) ──')
  {
    let bad = 0, iters = 8
    for (let i = 0; i < iters; i++) {
      clearAll()
      // #M: linha do BSTAFF (cliente CLI2) em 10:30 que o staff vai remarcar p/ 15:00
      const m = seedAppt({ barber: BSTAFF.uid, client: CLI2.uid, name: `${PFX} x3m-${i}`, email: CLI2.email, day: TUE, time: '10:30', status: 'confirmado' })
      const res = await Promise.all([
        callAsP(CLI.uid, book(CLI.uid, BSTAFF.uid, TUE, '15:00')),
        callAsP(BSTAFF.uid, staffResched(m, TUE, '15:00')),
      ])
      const [rBook, rResched] = res
      const rows15 = activeAt(BSTAFF.uid, TUE, '15:00')
      const mStat = apptCol(m, 'status')
      let okc = rows15 === 1 && noDeadlockAll(res) && won(res) === 1
      if (rBook.ok) {
        // cliente venceu → staff_reschedule falha (SLOT_TAKEN no núcleo) → #M INTACTO
        okc = okc && !rResched.ok && /SLOT_TAKEN/.test(rResched.err) && mStat === 'confirmado'
      } else {
        // staff venceu → #M cancelado + herdeiro em 15:00; book do cliente = SLOT_TAKEN
        okc = okc && rResched.ok && mStat === 'cancelado' && /SLOT_TAKEN/.test(rBook.err)
      }
      if (!okc) bad++
    }
    ok(`X3 ${iters}× book‖remarcar mesmo slot → 1 ocupa; se a remarca perde, o antigo fica ATIVO; 0 deadlock`, bad === 0, `bad=${bad}`)
    clearAll()
  }

  // ══════════════ X4 — cliente remarcar × staff remarcar o mesmo p_id ══════════════
  console.log('\n── X4 — cliente remarcar ‖ staff remarcar (mesmo p_id) ──')
  for (const [label, d1, t1, d2, t2] of [
    ['mesmo dia, slots distintos', TUE, '13:30', TUE, '16:30'],
    ['dias distintos', TUE, '13:30', THU, '13:30'],
  ]) {
    let bad = 0, iters = 8
    for (let i = 0; i < iters; i++) {
      clearAll()
      const n = seedAppt({ barber: BSTAFF.uid, client: CLI.uid, name: `${PFX} x4-${i}`, email: CLI.email, day: TUE, time: '10:30', status: 'confirmado' })
      const res = await Promise.all([
        callAsP(CLI.uid, cliResched(CLI.uid, n, BSTAFF.uid, d1, t1)),
        callAsP(BSTAFF.uid, staffResched(n, d2, t2)),
      ])
      const heirs = activeHeirs(BSTAFF.uid, CLI.uid, n)
      const nStat = apptCol(n, 'status')
      const okc = won(res) === 1 && heirs === 1 && nStat === 'cancelado' && noDeadlockAll(res) &&
        res.filter((x) => !x.ok).every((x) => DOMAIN.test(x.err))
      if (!okc) bad++
    }
    ok(`X4 (${label}) ${iters}× → sem deadlock, EXATAMENTE 1 herdeiro, antigo cancelado, perdedor P0001`, bad === 0, `bad=${bad}`)
    clearAll()
  }

  // ══════════════ X5 — cliente remarcar × cliente remarcar o mesmo p_id ══════════════
  console.log('\n── X5 — cliente remarcar ‖ cliente remarcar (mesmo p_id) ──')
  for (const [label, t1, d2, t2] of [
    ['mesmo dia, slots distintos', '13:30', TUE, '16:30'],
    ['dias distintos', '13:30', THU, '13:30'],
  ]) {
    let bad = 0, iters = 8
    for (let i = 0; i < iters; i++) {
      clearAll()
      const n = seedAppt({ barber: BSTAFF.uid, client: CLI.uid, name: `${PFX} x5-${i}`, email: CLI.email, day: TUE, time: '10:30', status: 'confirmado' })
      const res = await Promise.all([
        callAsP(CLI.uid, cliResched(CLI.uid, n, BSTAFF.uid, TUE, t1)),
        callAsP(CLI.uid, cliResched(CLI.uid, n, BSTAFF.uid, d2, t2)),
      ])
      const heirs = activeHeirs(BSTAFF.uid, CLI.uid, n)
      const okc = won(res) === 1 && heirs === 1 && apptCol(n, 'status') === 'cancelado' && noDeadlockAll(res) &&
        res.filter((x) => !x.ok).every((x) => /NOT_RESCHEDULABLE|NOT_FOUND/.test(x.err))
      if (!okc) bad++
    }
    ok(`X5 (${label}) ${iters}× → sem deadlock, 1 herdeiro, antigo cancelado, perdedor NOT_RESCHEDULABLE`, bad === 0, `bad=${bad}`)
    clearAll()
  }

  // ══════════════ X6 — lock de agenda ANTES da linha (sem inversão) ══════════════
  console.log('\n── X6 — os 2 reschedules travam a agenda ANTES de tocar a linha ──')
  {
    const n = seedAppt({ barber: BSTAFF.uid, client: CLI.uid, name: `${PFX} x6`, email: CLI.email, day: TUE, time: '10:30', status: 'confirmado' })
    const hold = spawn('docker', PSQL)
    hold.stdin.write(`begin;\nselect public._lock_agenda('${BSTAFF.uid}', date '${TUE}');\n`)
    await sleep(400)
    const probe = (uid, sql) => {
      try {
        execFileSync('docker', PSQL, { input:
          `begin;\nset local lock_timeout='800ms';\nset local role authenticated;\nset local request.jwt.claims to '{"sub":"${uid}","role":"authenticated"}';\n${sql}\ncommit;`,
          encoding: 'utf8' })
        return { ok: true }
      } catch (e) { return { ok: false, err: ((e.stderr || '') + (e.stdout || '')).toString() } }
    }
    const rs = probe(BSTAFF.uid, staffResched(n, TUE, '15:00'))
    const rc = probe(CLI.uid, cliResched(CLI.uid, n, BSTAFF.uid, TUE, '15:00'))
    hold.stdin.write('rollback;\n'); hold.stdin.end()
    await sleep(200)
    ok('X6 staff_reschedule bloqueia na agenda travada e NÃO cancela a linha',
      !rs.ok && /lock timeout|canceling statement/i.test(rs.err) && apptCol(n, 'status') === 'confirmado', `${ERR(rs.err)} n=${apptCol(n, 'status')}`)
    ok('X6 reschedule_appointment (cliente) bloqueia na agenda travada e NÃO cancela a linha',
      !rc.ok && /lock timeout|canceling statement/i.test(rc.err) && apptCol(n, 'status') === 'confirmado', `${ERR(rc.err)} n=${apptCol(n, 'status')}`)
    clearAll()
  }

  // ══════════════ X7 — caminho normal (sequencial) + erros de domínio ══════════════
  console.log('\n── X7 — sequencial: caminho normal + erros de domínio preservados ──')
  {
    clearAll()
    let r = tryCallAs(CLI.uid, book(CLI.uid, BSTAFF.uid, TUE, '10:30'))
    const bid = r.ok ? Number((r.out.match(/\d+/) || [])[0]) : null
    ok('X7 book_appointment normal → id, pendente', r.ok && bid > 0 && apptCol(bid, 'status') === 'pendente', r.ok ? `#${bid}` : ERR(r.err))

    r = tryCallAs(CLI.uid, cliResched(CLI.uid, bid, BSTAFF.uid, TUE, '13:30'))
    const nid = r.ok ? Number((r.out.match(/\d+/) || [])[0]) : null
    ok('X7 reschedule_appointment (cliente) normal → novo id, antigo cancelado',
      r.ok && nid > 0 && apptCol(bid, 'status') === 'cancelado' && apptCol(nid, 'status') === 'pendente', r.ok ? `#${bid}→#${nid}` : ERR(r.err))

    // ocupa 15:00 e tenta remarcar nid p/ lá → SLOT_TAKEN, nid intacto
    seedAppt({ barber: BSTAFF.uid, client: CLI2.uid, name: `${PFX} x7occ`, email: CLI2.email, day: TUE, time: '15:00', status: 'confirmado' })
    r = tryCallAs(CLI.uid, cliResched(CLI.uid, nid, BSTAFF.uid, TUE, '15:00'))
    ok('X7 cliente remarca p/ slot ocupado → SLOT_TAKEN, antigo intacto', !r.ok && /SLOT_TAKEN/.test(r.err) && apptCol(nid, 'status') === 'pendente', `${errOf(r.err)} n=${apptCol(nid, 'status')}`)

    r = tryCallAs(BSTAFF.uid, staffResched(nid, TUE, '16:30'))
    ok('X7 staff_reschedule normal (mesmo barbeiro) → sucesso', r.ok && Number((r.out.match(/\d+/) || [])[0]) > 0, r.ok ? 'ok' : ERR(r.err))
    clearAll()

    // terminal → NOT_RESCHEDULABLE (os 2)
    const term = seedAppt({ barber: BSTAFF.uid, client: CLI.uid, name: `${PFX} x7t`, email: CLI.email, day: TUE, time: '10:30', status: 'cancelado' })
    r = tryCallAs(CLI.uid, cliResched(CLI.uid, term, BSTAFF.uid, TUE, '13:30'))
    ok('X7 cliente remarca terminal → NOT_RESCHEDULABLE', !r.ok && /NOT_RESCHEDULABLE/.test(r.err), errOf(r.err))
    r = tryCallAs(BSTAFF.uid, staffResched(term, TUE, '13:30'))
    ok('X7 staff remarca terminal → NOT_RESCHEDULABLE', !r.ok && /NOT_RESCHEDULABLE/.test(r.err), errOf(r.err))
    clearAll()

    // book p/ ontem → PAST_DAY ; staff legado STAFF_NOT_ALLOWED pelo caminho do cliente
    r = tryCallAs(CLI.uid, `select public.book_appointment('${BSTAFF.uid}', date '${ONTEM}', '10:30', array[${SVC45}]::bigint[]);`)
    ok('X7 book p/ ontem → PAST_DAY', !r.ok && /PAST_DAY/.test(r.err), errOf(r.err))
    r = tryCallAs(BSTAFF.uid, book(BSTAFF.uid, BSTAFF.uid, TUE, '10:30'))
    ok('X7 staff pelo caminho do cliente → STAFF_NOT_ALLOWED', !r.ok && /STAFF_NOT_ALLOWED/.test(r.err), errOf(r.err))
    clearAll()
  }

  const finalCount = psql(`select count(*) from public.appointments;`)
  console.log(`\n${fail === 0 ? '✅ TODOS OS TESTES PASSARAM' : '❌ HÁ FALHAS'} — ${pass} ok / ${fail} falhas   (appointments no lab: ${finalCount})\n`)
}

function limpar() {
  // varre a FAMÍLIA 'st1b5-%' (não só este rid) — um run morto por SIGTERM se
  // auto-cura no próximo. Nunca toca linha sem o prefixo.
  psql(`
    delete from public.notifications where appt_id in (select id from public.appointments where client_name like 'st1b5-%')
      or recipient_client_id in (select id from auth.users where email like 'st1b5-%')
      or recipient_barber_id in (select id from auth.users where email like 'st1b5-%');
    delete from public.appointments where client_name like 'st1b5-%'
      or client_id in (select id from auth.users where email like 'st1b5-%')
      or barber_id in (select id from auth.users where email like 'st1b5-%');
    delete from public.crm_clients where barber_id in (select id from auth.users where email like 'st1b5-%') or name like 'st1b5-%';
    delete from public.clients where id in (select id from auth.users where email like 'st1b5-%');
    delete from public.barbers where id in (select id from auth.users where email like 'st1b5-%');
    delete from auth.users where email like 'st1b5-%';`)
  const c = psql(`select count(*) from public.appointments;`)
  console.log(`(limpeza concluída — appointments no lab: ${c})`)
}

try { await main() } catch (e) { console.error('\nERRO FATAL:', e.stack || e.message); fail++ }
finally { try { limpar() } catch (e) { console.error('limpeza falhou:', e.message) } }
process.exit(fail === 0 ? 0 : 1)
