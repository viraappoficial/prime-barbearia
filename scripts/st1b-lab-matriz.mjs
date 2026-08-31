/**
 * ST-1b · matriz G0 + R1–R20 + E1–E27 contra o LAB (localhost:8100 / supabase-db).
 *
 * Cobre `staff_reschedule_appointment` e `staff_book_encaixe` (+ o núcleo
 * `_staff_insert_appointment` e o helper `_staff_can_book_for`).
 *
 * - aplica as 4 migrations ST-1b.0–3 (idempotente) e deixa APLICADAS;
 * - semeia barbeiros/clientes/híbrido de teste + agendamentos;
 * - roda a matriz via psql (`set local role` + `request.jwt.claims`) e algumas
 *   corridas reais (processos psql separados);
 * - LIMPA os dados de teste — o lab volta a 37 appointments (os 10 ativos que a
 *   ST-1b.0 backfillou PERMANECEM com `duration` preenchida — é o ponto da .0);
 * - despeja evidências (pg_proc / grants / secdef / search_path).
 *
 * Nunca toca produção, db push nem cutover. Uso: node scripts/st1b-lab-matriz.mjs
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
]

const AK = readFileSync('/home/gabrielparcel/projetos/prime-next/.env.local', 'utf8')
  .split('\n').find((l) => l.startsWith('NEXT_PUBLIC_SUPABASE_ANON_KEY=')).split('=')[1].trim()
const anonH = { apikey: AK, 'Content-Type': 'application/json' }

const PSQL = ['exec', '-i', 'supabase-db', 'psql', '-U', 'postgres', '-d', 'postgres', '-qtAX', '-v', 'ON_ERROR_STOP=1']
const psql = (s) => execFileSync('docker', PSQL, { input: s, encoding: 'utf8' }).trim()
const tryPsql = (s) => {
  try { return { ok: true, out: psql(s) } }
  catch (e) { return { ok: false, err: ((e.stderr || '') + (e.stdout || '') || e.message).toString() } }
}
// psql com stderr (NOTICE) mesclado no stdout — para checar `raise notice` de migrations
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
const PFX = `st1b-${rid}`
let pass = 0, fail = 0
const ok = (n, c, extra = '') => {
  c ? pass++ : fail++
  console.log(`  ${c ? 'OK  ' : 'FAIL'} ${n}${extra ? `  — ${String(extra).replace(/\s+/g, ' ').slice(0, 150)}` : ''}`)
}
const ERR = (s) => (String(s).split('\n').find((l) => /ERROR|DETAIL/.test(l)) || String(s).slice(0, 120)).trim()
const errcode = (m) => (String(m).match(/NOT_[A-Z_]+|BAD_[A-Z_]+|PAST_DAY|OUT_OF_WINDOW|BARBER_OFF|SLOT_TAKEN|SERVICE_INVALID|CLIENT_INVALID|WALKIN_[A-Z_]+|OVERLAP_UNCHECKED|22P02|P0001/) || ['?'])[0]

// ── serviços (catálogo do lab) ──
const SVC30 = 1   // Corte Social  30
const SVC45 = 2   // Corte Degradê 45
const SVC15 = 5   // Acabamento    15
const SVC90 = 16  // Botox capilar 90

// ── datas no fuso da loja ──
const TZ = "(select timezone from public.shop_settings where id = 1)"
const dateForDow = (dow, minAhead = 1) => psql(
  `select g::date::text from generate_series((now() at time zone ${TZ})::date + ${minAhead}, (now() at time zone ${TZ})::date + 20, interval '1 day') g
   where extract(dow from g) = ${dow} order by g limit 1;`)
const HOJE = psql(`select (now() at time zone ${TZ})::date::text;`)
const ONTEM = psql(`select ((now() at time zone ${TZ})::date - 1)::text;`)
const NOW_MIN = Number(psql(`select (extract(hour from now() at time zone ${TZ})*60 + extract(minute from now() at time zone ${TZ}))::int;`))
const DOW_HOJE = Number(psql(`select extract(dow from now() at time zone ${TZ})::int;`))
let TUE, WED  // dia feliz (barbeiro atende) / dia de folga do barbeiro A

// hours do barbeiro A: espelha a loja mas com QUARTA (dow 3) de folga
const HOURS_A = '{"0":null,"1":["09:00","20:00"],"2":["09:00","20:00"],"3":null,"4":["09:00","20:00"],"5":["09:00","20:00"],"6":["09:00","18:00"]}'

let CLI, CLI2, BARBA, BARBB, VEND, ADM, HYB
async function signup(tag) {
  const email = `${PFX}-${tag}@prime-lab.local`
  const r = await fetch(`${LAB}/auth/v1/signup`, { method: 'POST', headers: anonH, body: JSON.stringify({ email, password: 'Test-1234!' }) })
  const d = await r.json()
  if (!d.user?.id) throw new Error(`signup ${tag}: ${JSON.stringify(d)}`)
  return { uid: d.user.id, tok: d.access_token, email }
}

// insere um agendamento (como postgres — igual ao staff legado). Duração explícita.
function seedAppt({ barber, client = null, name, email = null, day, time, dur = 45, status = 'pendente', enc = false, services = "array['Corte Degradê']", started = false }) {
  return Number(psql(
    `insert into public.appointments (client_id, barber_id, services, day, day_label, time, duration, status, is_encaixe, iniciado_em, client_name, client_email)
     values (${client ? `'${client}'` : 'null'}, '${barber}', ${services}, date '${day}', 'x', '${time}', ${dur === null ? 'null' : dur},
             '${status}', ${enc}, ${started ? 'now()' : 'null'}, '${name}', ${email ? `'${email}'` : 'null'})
     returning id;`))
}
const apptCol = (id, c) => psql(`select coalesce(${c}::text,'<null>') from public.appointments where id = ${id};`)
const clearAgenda = (barber, day) => psql(`delete from public.notifications where appt_id in (select id from public.appointments where barber_id='${barber}' and day=date '${day}' and client_name like '${PFX}%'); delete from public.appointments where barber_id='${barber}' and day=date '${day}' and client_name like '${PFX}%';`)
const notifsFor = (apptId) => psql(`select coalesce(string_agg(for_role||'/'||type||'/'||coalesce(recipient_client_id::text,'∅'),';'),'(nenhuma)') from public.notifications where appt_id = ${apptId};`)

// RPC calls
const resched = (uid, id, day, time) => tryCallAs(uid, `select public.staff_reschedule_appointment(${id}, date '${day}', '${time}');`)
const encaixe = (uid, { barber, ref, day, time, svc = `array[${SVC45}]::bigint[]`, notes = 'null', notify = true }) =>
  tryCallAs(uid, `select public.staff_book_encaixe('${barber}', ${ref}, date '${day}', '${time}', ${svc}, ${notes === 'null' ? 'null' : `'${notes}'`}, ${notify});`)
const refAccount = (uid) => `jsonb_build_object('mode','account','id','${uid}')`
const refWalkin = (name, phone) => `jsonb_build_object('mode','walkin','name','${name}','phone','${phone}')`
const idOf = (r) => (r.ok ? Number((r.out.match(/\d+/) || [])[0]) : null)

async function seed() {
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
}

async function main() {
  console.log(`\n╔══ ST-1b — matriz G0 + R1–R20 + E1–E27 (lab, prefixo ${PFX}) ══╗`)
  console.log('· aplicando ST-1b.0–3 (idempotente) ...')
  for (const f of FILES) psqlFile(new URL(f, MIG).pathname)
  await reloadPgrst()
  await seed()
  TUE = dateForDow(2); WED = dateForDow(3); const SUN = dateForDow(0)
  console.log(`· seed ok — TUE(feliz)=${TUE}  WED(folga de A)=${WED}  SUN(loja fechada)=${SUN}  hoje=${HOJE} (dow ${DOW_HOJE}, ${NOW_MIN}min)\n`)

  // ════════════════ GATE 0 — ST-1b.0 preflight ════════════════
  console.log('── G0 — ST-1b.0 (preflight de duration NULL) ──')
  {
    // já rodou na aplicação: os 10 ativos NULL viraram numéricos
    const nullAtivos = psql(`select count(*) from public.appointments where status in ('pendente','confirmado') and duration is null;`)
    ok('G0.1 após ST-1b.0: 0 agendamentos ativos com duration NULL', nullAtivos === '0', `restam ${nullAtivos}`)
    const backfilled = psql(`select string_agg(id||'='||duration,',' order by id) from public.appointments where id in (16,56,60,64,65,66,69,70,71,72);`)
    ok('G0.1 os 10 ativos conhecidos têm duration = soma do catálogo', backfilled === '16=45,56=105,60=30,64=45,65=45,66=45,69=30,70=30,71=45,72=110', backfilled)

    // re-rodar a migration → no-op registrado (idempotente por resultado)
    const rerun = psqlFile(new URL(FILES[0], MIG).pathname)
    ok('G0.1 re-rodar ST-1b.0 → no-op registrado (0 ativos NULL)', /no-op — 0 agendamentos/.test(rerun), rerun.replace(/\s+/g, ' ').trim().slice(0, 90))

    // semear um ativo NULL resolvível → o bloco do preflight backfilla pela soma
    const rid1 = seedAppt({ barber: BARBB.uid, name: `${PFX} g0resolv`, day: TUE, time: '09:00', dur: null, services: "array['Corte Social','Acabamento']" })
    // (o trigger _fill_appointment_duration preenche com slot_min; forçar NULL de novo p/ simular acervo legado)
    psql(`update public.appointments set duration = null where id = ${rid1};`)
    const pre = psql(`
      do $$ declare v_null int; v_bad int; begin
        select count(*) into v_null from public.appointments where status in ('pendente','confirmado') and duration is null;
        select count(*) into v_bad from public.appointments a where a.status in ('pendente','confirmado') and a.duration is null
          and coalesce(cardinality(a.services),0) <> (select count(*) from public.services s where s.name = any(a.services));
        raise notice 'null=% bad=%', v_null, v_bad;
        if v_bad = 0 then update public.appointments a set duration = (select sum(s.duration_min) from public.services s where s.name = any(a.services))
          where a.status in ('pendente','confirmado') and a.duration is null; end if;
      end $$;`)
    ok('G0.1 ativo NULL resolvível → backfill dirigido (soma real 30+15=45)', apptCol(rid1, 'duration') === '45', `dur=${apptCol(rid1, 'duration')} | ${pre.replace(/\s+/g, ' ').slice(0, 60)}`)

    // semear um ativo NULL NÃO-resolvível → o preflight aborta com os ids
    const rid2 = seedAppt({ barber: BARBB.uid, name: `${PFX} g0bad`, day: TUE, time: '09:45', dur: null, services: "array['Servico Fantasma XYZ']" })
    psql(`update public.appointments set duration = null where id = ${rid2};`)
    const abort = tryPsql(`do $$ declare v_bad int; v_ids bigint[]; begin
      select count(*), array_agg(a.id order by a.id) into v_bad, v_ids from public.appointments a
        where a.status in ('pendente','confirmado') and a.duration is null
          and coalesce(cardinality(a.services),0) <> (select count(*) from public.services s where s.name = any(a.services));
      if v_bad > 0 then raise exception 'ST-1b.0 abortada: % (ids: %)', v_bad, v_ids using errcode='P0001'; end if;
    end $$;`)
    ok('G0.1 ativo NULL não-resolvível → ABORTA listando o id', !abort.ok && abort.err.includes(String(rid2)) && /ST-1b\.0 abortada/.test(abort.err), ERR(abort.err))
    psql(`delete from public.appointments where id in (${rid1}, ${rid2});`)

    // G0.2 — o passo 9 do núcleo nunca compara com NULL: linha INATIVA NULL é ignorada
    const inativaNull = seedAppt({ barber: BARBA.uid, name: `${PFX} g02inativa`, day: TUE, time: '10:30', dur: null, status: 'cancelado' })
    psql(`update public.appointments set duration = null where id = ${inativaNull};`)
    const r02 = encaixe(BARBA.uid, { barber: BARBA.uid, ref: refAccount(CLI.uid), day: TUE, time: '10:30' })
    ok('G0.2 linha INATIVA com duration NULL não entra na sobreposição', r02.ok && idOf(r02) > 0, r02.ok ? `novo id ${idOf(r02)}` : ERR(r02.err))
    // e uma ATIVA NULL (corrida com escrita legada) → OVERLAP_UNCHECKED  (BARBB: hours null → Tue aberto)
    const ativaNull = seedAppt({ barber: BARBB.uid, name: `${PFX} g02ativa`, day: TUE, time: '11:00', dur: null, status: 'confirmado' })
    psql(`update public.appointments set duration = null where id = ${ativaNull};`)
    const r02b = encaixe(BARBB.uid, { barber: BARBB.uid, ref: refAccount(CLI.uid), day: TUE, time: '15:00' })
    ok('G0.2 ATIVA com duration NULL → OVERLAP_UNCHECKED (não insere, sem fallback)',
      !r02b.ok && /OVERLAP_UNCHECKED/.test(r02b.err), ERR(r02b.err))
    clearAgenda(BARBA.uid, TUE); clearAgenda(BARBB.uid, TUE)
  }

  // ════════════════ RESCHEDULE — R1–R20 ════════════════
  console.log('\n── R — staff_reschedule_appointment ──')
  {
    // R1 — barbeiro A remarca a própria linha (slot da grade)
    clearAgenda(BARBA.uid, TUE)
    let a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} r1`, email: CLI.email, day: TUE, time: '10:30', status: 'confirmado' })
    let r = resched(BARBA.uid, a, TUE, '15:00')
    let nid = idOf(r)
    ok('R1 barbeiro remarca a própria linha (grade) → novo id', r.ok && nid > 0, r.ok ? `#${a}→#${nid}` : ERR(r.err))
    ok('R1 status preservado (confirmado) + antigo cancelado', nid && apptCol(nid, 'status') === 'confirmado' && apptCol(a, 'status') === 'cancelado', `old=${apptCol(a, 'status')} new=${nid && apptCol(nid, 'status')}`)
    ok('R1 novo herda barbeiro/cliente/serviços/duração', nid && apptCol(nid, 'barber_id') === BARBA.uid && apptCol(nid, 'client_id') === CLI.uid && apptCol(nid, 'duration') === '45', `${nid && apptCol(nid, 'duration')}`)
    clearAgenda(BARBA.uid, TUE)

    // R2 — mover p/ o slot adjacente da grade (prova: cancelar-antes-de-inserir)
    a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} r2`, email: CLI.email, day: TUE, time: '10:30', dur: 45, status: 'confirmado' })
    r = resched(BARBA.uid, a, TUE, '11:15')  // 11:15 = 10:30+45 → encostaria em si mesmo
    ok('R2 move p/ slot adjacente (11:15) → sucesso (não colide consigo mesmo)', r.ok && idOf(r) > 0, r.ok ? `#${idOf(r)}` : ERR(r.err))
    clearAgenda(BARBA.uid, TUE)

    // R2b/R13 — reschedule NORMAL fora da grade → BAD_SLOT
    a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} r2b`, email: CLI.email, day: TUE, time: '10:30', status: 'confirmado' })
    r = resched(BARBA.uid, a, TUE, '10:45')  // 15min à frente, fora da grade de 45
    ok('R2b/R13 reschedule normal fora da grade → BAD_SLOT', !r.ok && /BAD_SLOT/.test(r.err) && apptCol(a, 'status') === 'confirmado', `${errcode(r.err)} old=${apptCol(a, 'status')}`)
    clearAgenda(BARBA.uid, TUE)

    // R3 — remarca p/ horário ocupado por outra linha ativa do mesmo barbeiro
    a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} r3a`, email: CLI.email, day: TUE, time: '10:30', status: 'confirmado' })
    seedAppt({ barber: BARBA.uid, client: CLI2.uid, name: `${PFX} r3b`, email: CLI2.email, day: TUE, time: '13:30', status: 'confirmado' })
    r = resched(BARBA.uid, a, TUE, '13:30')
    ok('R3 remarca p/ slot ocupado → SLOT_TAKEN, antigo intacto e ativo', !r.ok && /SLOT_TAKEN/.test(r.err) && apptCol(a, 'status') === 'confirmado', `${errcode(r.err)} old=${apptCol(a, 'status')}`)
    clearAgenda(BARBA.uid, TUE)

    // R4 — remarca p/ dia de folga do barbeiro (quarta, HOURS_A[3]=null)
    a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} r4`, email: CLI.email, day: TUE, time: '10:30', status: 'confirmado' })
    r = resched(BARBA.uid, a, WED, '10:30')
    ok('R4 remarca p/ dia de folga → BARBER_OFF, antigo intacto', !r.ok && /BARBER_OFF/.test(r.err) && apptCol(a, 'status') === 'confirmado', `${errcode(r.err)} old=${apptCol(a, 'status')}`)
    clearAgenda(BARBA.uid, TUE)

    // R5 — remarca p/ ontem (fuso da loja)
    a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} r5`, email: CLI.email, day: TUE, time: '10:30', status: 'confirmado' })
    r = resched(BARBA.uid, a, ONTEM, '10:30')
    ok('R5 remarca p/ ontem → PAST_DAY', !r.ok && /PAST_DAY/.test(r.err), errcode(r.err))
    clearAgenda(BARBA.uid, TUE)

    // R6 — remarca agendamento terminal
    for (const st of ['concluido', 'cancelado', 'nao_compareceu']) {
      a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} r6`, email: CLI.email, day: TUE, time: '10:30', status: st })
      r = resched(BARBA.uid, a, TUE, '15:00')
      ok(`R6 remarca ${st} → NOT_RESCHEDULABLE`, !r.ok && /NOT_RESCHEDULABLE/.test(r.err), errcode(r.err))
      clearAgenda(BARBA.uid, TUE)
    }

    // R7 — remarca agendamento em atendimento
    a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} r7`, email: CLI.email, day: TUE, time: '10:30', status: 'confirmado', started: true })
    r = resched(BARBA.uid, a, TUE, '15:00')
    ok('R7 remarca em atendimento (iniciado_em set) → NOT_RESCHEDULABLE', !r.ok && /NOT_RESCHEDULABLE/.test(r.err), errcode(r.err))
    clearAgenda(BARBA.uid, TUE)

    // R8 — barbeiro B remarca a linha do barbeiro A
    a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} r8`, email: CLI.email, day: TUE, time: '10:30', status: 'confirmado' })
    r = resched(BARBB.uid, a, TUE, '15:00')
    ok('R8 barbeiro B remarca linha de A → NOT_FOUND (não vaza posse), A intacto', !r.ok && /NOT_FOUND/.test(r.err) && apptCol(a, 'status') === 'confirmado', `${errcode(r.err)} old=${apptCol(a, 'status')}`)
    clearAgenda(BARBA.uid, TUE)

    // R9 — admin remarca a linha de A
    a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} r9`, email: CLI.email, day: TUE, time: '10:30', status: 'confirmado' })
    r = resched(ADM.uid, a, TUE, '15:00')
    ok('R9 admin remarca linha de A → sucesso', r.ok && idOf(r) > 0, r.ok ? `#${idOf(r)}` : ERR(r.err))
    clearAgenda(BARBA.uid, TUE)

    // R10 — vendas remarca a linha de A (D-1b-1)
    a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} r10`, email: CLI.email, day: TUE, time: '10:30', status: 'confirmado' })
    r = resched(VEND.uid, a, TUE, '15:00')
    ok('R10 vendas remarca linha de A → sucesso (D-1b-1)', r.ok && idOf(r) > 0, r.ok ? `#${idOf(r)}` : ERR(r.err))
    clearAgenda(BARBA.uid, TUE)

    // R11 — cliente chama a RPC
    a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} r11`, email: CLI.email, day: TUE, time: '10:30', status: 'confirmado' })
    r = resched(CLI.uid, a, TUE, '15:00')
    ok('R11 cliente chama staff_reschedule_appointment → NOT_STAFF', !r.ok && /NOT_STAFF/.test(r.err), errcode(r.err))
    r = resched(null, a, TUE, '15:00')
    ok('R11 anon chama staff_reschedule_appointment → negado', !r.ok && /NOT_AUTH|permission denied|42501/.test(r.err), ERR(r.err))
    clearAgenda(BARBA.uid, TUE)

    // R12 — híbrido remarca o próprio agendamento COMO CLIENTE (outro barbeiro)
    const hybAsClient = seedAppt({ barber: BARBB.uid, client: HYB.uid, name: `${PFX} r12`, email: HYB.email, day: TUE, time: '10:30', status: 'confirmado' })
    r = resched(HYB.uid, hybAsClient, TUE, '15:00')
    ok('R12 híbrido remarca a própria linha-como-cliente via staff_reschedule → NOT_FOUND', !r.ok && /NOT_FOUND/.test(r.err) && apptCol(hybAsClient, 'status') === 'confirmado', `${errcode(r.err)}`)
    clearAgenda(BARBB.uid, TUE)

    // R14 — reschedule de um ENCAIXE p/ outro horário fora da grade (shift 15min)
    a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} r14`, email: CLI.email, day: TUE, time: '13:07', dur: 45, status: 'confirmado', enc: true })
    r = resched(BARBA.uid, a, TUE, '13:22')
    nid = idOf(r)
    ok('R14 reschedule de encaixe off-grid (13:07→13:22) → sucesso, is_encaixe preservado', r.ok && nid > 0 && apptCol(nid, 'is_encaixe') === 'true', r.ok ? `#${nid} enc=${apptCol(nid, 'is_encaixe')}` : ERR(r.err))
    clearAgenda(BARBA.uid, TUE)

    // R15 — corrida: 2 sessões remarcam p/ o mesmo slot livre
    const c1 = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} r15a`, email: CLI.email, day: TUE, time: '09:00', dur: 45, status: 'confirmado' })
    const c2 = seedAppt({ barber: BARBA.uid, client: CLI2.uid, name: `${PFX} r15b`, email: CLI2.email, day: TUE, time: '09:45', dur: 45, status: 'confirmado' })
    const [ra, rb] = await Promise.all([
      callAsP(ADM.uid, `select public.staff_reschedule_appointment(${c1}, date '${TUE}', '16:30');`),
      callAsP(ADM.uid, `select public.staff_reschedule_appointment(${c2}, date '${TUE}', '16:30');`),
    ])
    const wins = [ra, rb].filter((x) => x.ok).length
    const takens = [ra, rb].filter((x) => !x.ok && /SLOT_TAKEN/.test(x.err)).length
    const rows = psql(`select count(*) from public.appointments where barber_id='${BARBA.uid}' and day=date '${TUE}' and time='16:30' and status in ('pendente','confirmado');`)
    ok('R15 corrida p/ mesmo slot → 1 vence, 1 SLOT_TAKEN, 1 linha', wins === 1 && takens === 1 && rows === '1', `wins=${wins} takens=${takens} rows=${rows}`)
    clearAgenda(BARBA.uid, TUE)

    // R16 — atomicidade: reschedule que falha no núcleo (BARBER_OFF) → antigo volta a ativo
    a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} r16`, email: CLI.email, day: TUE, time: '10:30', status: 'pendente' })
    r = resched(BARBA.uid, a, WED, '10:30')
    ok('R16 atomicidade: falha no núcleo → rollback, antigo volta a ativo (não cancelado)', !r.ok && apptCol(a, 'status') === 'pendente', `err=${errcode(r.err)} old=${apptCol(a, 'status')}`)
    clearAgenda(BARBA.uid, TUE)

    // R17 — notif
    a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} r17a`, email: CLI.email, day: TUE, time: '10:30', status: 'confirmado' })
    r = resched(BARBA.uid, a, TUE, '15:00'); nid = idOf(r)
    ok('R17 reschedule c/ conta → 1 notif remarcado for_role=client', nid && notifsFor(nid) === `client/remarcado/${CLI.uid}`, notifsFor(nid))
    clearAgenda(BARBA.uid, TUE)
    a = seedAppt({ barber: BARBA.uid, name: `${PFX} r17w`, day: TUE, time: '10:30', dur: 45, status: 'confirmado', enc: true })  // walk-in (client_id null)
    r = resched(BARBA.uid, a, TUE, '13:15'); nid = idOf(r)
    ok('R17 reschedule walk-in (sem conta) → 0 notifs', nid && notifsFor(nid) === '(nenhuma)', notifsFor(nid))
    clearAgenda(BARBA.uid, TUE)

    // R18 — regressão legado: #barberApp faz UPDATE {day,day_label,time} direto
    a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} r18`, email: CLI.email, day: TUE, time: '10:30', status: 'confirmado' })
    r = tryCallAs(BARBA.uid, `update public.appointments set day = date '${TUE}', day_label = 'Ter 01/01', time = '11:15' where id = ${a};`)
    ok('R18 regressão: staff legado UPDATE direto {day,day_label,time} → passa (guard ST-H libera)', r.ok && apptCol(a, 'time') === '11:15', r.ok ? `time=${apptCol(a, 'time')}` : ERR(r.err))
    clearAgenda(BARBA.uid, TUE)

    // R19 — reschedule de ativo com duration NULL cujos services TODOS resolvem
    a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} r19`, email: CLI.email, day: TUE, time: '10:30', dur: 45, status: 'confirmado', services: "array['Corte Social','Acabamento']" })
    psql(`update public.appointments set duration = null where id = ${a};`)  // simula acervo legado (corrida pós-backfill)
    r = resched(BARBA.uid, a, TUE, '15:00'); nid = idOf(r)
    ok('R19 reschedule de ativo NULL c/ services resolvíveis → v_dur do catálogo (30+15=45)', r.ok && nid && apptCol(nid, 'duration') === '45', r.ok ? `dur=${apptCol(nid, 'duration')}` : ERR(r.err))
    clearAgenda(BARBA.uid, TUE)

    // R20 — reschedule de ativo com duration NULL cujos services NÃO resolvem
    a = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} r20`, email: CLI.email, day: TUE, time: '10:30', dur: 45, status: 'confirmado', services: "array['Servico Fantasma XYZ']" })
    psql(`update public.appointments set duration = null where id = ${a};`)
    r = resched(BARBA.uid, a, TUE, '15:00')
    ok('R20 reschedule de ativo NULL c/ services não-resolvíveis → OVERLAP_UNCHECKED, antigo intacto', !r.ok && /OVERLAP_UNCHECKED/.test(r.err) && apptCol(a, 'status') === 'confirmado', `${errcode(r.err)} old=${apptCol(a, 'status')}`)
    clearAgenda(BARBA.uid, TUE)
  }

  // ════════════════ ENCAIXE — E1–E27 ════════════════
  console.log('\n── E — staff_book_encaixe ──')
  {
    // E1 — barbeiro A, account, off-grid, 45min
    clearAgenda(BARBA.uid, TUE)
    let r = encaixe(BARBA.uid, { barber: BARBA.uid, ref: refAccount(CLI.uid), day: TUE, time: '13:07' })
    let nid = idOf(r)
    ok('E1 encaixe account off-grid → is_encaixe=true, status=confirmado, client_id set, dur=45',
      r.ok && nid && apptCol(nid, 'is_encaixe') === 'true' && apptCol(nid, 'status') === 'confirmado' && apptCol(nid, 'client_id') === CLI.uid && apptCol(nid, 'duration') === '45',
      r.ok ? `#${nid}` : ERR(r.err))
    clearAgenda(BARBA.uid, TUE)

    // E2 — walk-in nome+telefone novos
    r = encaixe(BARBA.uid, { barber: BARBA.uid, ref: refWalkin(`${PFX} Zé Walk`, '11987654321'), day: TUE, time: '13:07' })
    nid = idOf(r)
    const crm = psql(`select barber_id||'|'||name||'|'||coalesce(phone,'∅') from public.crm_clients where barber_id='${BARBA.uid}' and lower(name)=lower('${PFX} Zé Walk');`)
    ok('E2 walk-in novo → crm_clients criado (barber=A), appt client_id NULL, client_name = nome, 0 notif',
      r.ok && nid && apptCol(nid, 'client_id') === '<null>' && apptCol(nid, 'client_name') === `${PFX} Zé Walk` && crm === `${BARBA.uid}|${PFX} Zé Walk|11987654321` && notifsFor(nid) === '(nenhuma)',
      `crm=${crm} notif=${nid && notifsFor(nid)}`)
    clearAgenda(BARBA.uid, TUE)

    // E3 — walk-in nome já na carteira, sem telefone gravado → reusa + completa phone
    psql(`insert into public.crm_clients (barber_id,name) values ('${BARBA.uid}','${PFX} SemTel');`)
    const crmBefore = psql(`select count(*) from public.crm_clients where barber_id='${BARBA.uid}' and lower(name)=lower('${PFX} SemTel');`)
    r = encaixe(BARBA.uid, { barber: BARBA.uid, ref: refWalkin(`${PFX} SemTel`, '11 91111-2222'), day: TUE, time: '13:07' })
    const crmAfter = psql(`select count(*)||'|'||coalesce(max(phone),'∅') from public.crm_clients where barber_id='${BARBA.uid}' and lower(name)=lower('${PFX} SemTel');`)
    ok('E3 walk-in nome na carteira sem telefone → reusa + completa phone, não duplica', r.ok && crmBefore === '1' && crmAfter === '1|11911112222', `before=${crmBefore} after=${crmAfter}`)
    clearAgenda(BARBA.uid, TUE)

    // E4 — walk-in telefone já na carteira + nome bate → reusa por telefone
    psql(`insert into public.crm_clients (barber_id,name,phone) values ('${BARBA.uid}','${PFX} ComTel','11933334444');`)
    r = encaixe(BARBA.uid, { barber: BARBA.uid, ref: refWalkin(`${PFX} ComTel`, '5511933334444'), day: TUE, time: '13:07' })  // DDI 55
    nid = idOf(r)
    const crm4 = psql(`select count(*) from public.crm_clients where barber_id='${BARBA.uid}' and phone='11933334444';`)
    ok('E4 walk-in telefone na carteira (c/ DDI) + nome bate → reusa, não duplica', r.ok && nid > 0 && crm4 === '1', `rows=${crm4}`)
    clearAgenda(BARBA.uid, TUE)

    // E4b — telefone bate mas nome informado é diferente → WALKIN_CONFLICT
    r = encaixe(BARBA.uid, { barber: BARBA.uid, ref: refWalkin(`${PFX} OutroNome`, '11933334444'), day: TUE, time: '13:07' })
    ok('E4b walk-in telefone bate, nome diferente → WALKIN_CONFLICT (não reusa, não cria)', !r.ok && /WALKIN_CONFLICT/.test(r.err), errcode(r.err))

    // E4c — 2+ linhas na carteira com o mesmo telefone normalizado → WALKIN_CONFLICT
    psql(`insert into public.crm_clients (barber_id,name,phone) values ('${BARBA.uid}','${PFX} Dup1','11955556666'),('${BARBA.uid}','${PFX} Dup2','+55 11 95555-6666');`)
    r = encaixe(BARBA.uid, { barber: BARBA.uid, ref: refWalkin(`${PFX} Dup1`, '11955556666'), day: TUE, time: '13:07' })
    ok('E4c 2 linhas mesmo telefone normalizado → WALKIN_CONFLICT', !r.ok && /WALKIN_CONFLICT/.test(r.err), errcode(r.err))

    // E4d — homônimo (2+ mesma (barber, lower(name))): impedido pelo índice único do schema
    const dup = tryPsql(`insert into public.crm_clients (barber_id,name) values ('${BARBA.uid}','${PFX} ComTel');`)
    ok('E4d 2º homônimo (barber, lower(name)) → barrado pelo índice único crm_clients_barber_name_idx (branch WALKIN_CONFLICT é defesa)', !dup.ok && /crm_clients_barber_name_idx|duplicate key/.test(dup.err), ERR(dup.err))
    clearAgenda(BARBA.uid, TUE)

    // E5 — encaixe sobre intervalo ocupado (horário exato "vazio")
    seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} e5occ`, email: CLI.email, day: TUE, time: '13:00', dur: 45, status: 'confirmado' })  // ocupa 13:00-13:45
    r = encaixe(BARBA.uid, { barber: BARBA.uid, ref: refAccount(CLI2.uid), day: TUE, time: '13:20' })
    ok('E5 encaixe dentro de intervalo ocupado → SLOT_TAKEN (sem overbooking)', !r.ok && /SLOT_TAKEN/.test(r.err), errcode(r.err))
    clearAgenda(BARBA.uid, TUE)

    // E6 — encaixe de 90min que sobrepõe um agendamento 45min à frente
    seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} e6`, email: CLI.email, day: TUE, time: '14:00', dur: 45, status: 'confirmado' })
    r = encaixe(BARBA.uid, { barber: BARBA.uid, ref: refAccount(CLI2.uid), day: TUE, time: '13:15', svc: `array[${SVC90}]::bigint[]` })
    ok('E6 encaixe 90min sobrepõe agendamento à frente → SLOT_TAKEN', !r.ok && /SLOT_TAKEN/.test(r.err), errcode(r.err))
    clearAgenda(BARBA.uid, TUE)

    // E7 — gap real de 30min: 1 encaixe entra, 2º no mesmo gap → SLOT_TAKEN
    seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} e7a`, email: CLI.email, day: TUE, time: '13:00', dur: 45, status: 'confirmado' })   // 13:00-13:45
    seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} e7b`, email: CLI.email, day: TUE, time: '14:15', dur: 45, status: 'confirmado' })   // 14:15-15:00 → gap 13:45-14:15
    r = encaixe(BARBA.uid, { barber: BARBA.uid, ref: refAccount(CLI2.uid), day: TUE, time: '13:45', svc: `array[${SVC30}]::bigint[]` })
    ok('E7 encaixe 30min num gap real de 30min → sucesso', r.ok && idOf(r) > 0, r.ok ? `#${idOf(r)}` : ERR(r.err))
    r = encaixe(BARBA.uid, { barber: BARBA.uid, ref: refAccount(CLI.uid), day: TUE, time: '13:50', svc: `array[${SVC15}]::bigint[]` })
    ok('E7 2º encaixe no mesmo gap → SLOT_TAKEN', !r.ok && /SLOT_TAKEN/.test(r.err), errcode(r.err))
    clearAgenda(BARBA.uid, TUE)

    // E8 — encaixe em dia de folga do barbeiro
    r = encaixe(BARBA.uid, { barber: BARBA.uid, ref: refAccount(CLI.uid), day: WED, time: '13:07' })
    ok('E8 encaixe em dia de folga → BARBER_OFF', !r.ok && /BARBER_OFF/.test(r.err), errcode(r.err))

    // E9 — encaixe antes da abertura / depois do fechamento (não cabe na janela da loja)
    r = encaixe(BARBA.uid, { barber: BARBA.uid, ref: refAccount(CLI.uid), day: TUE, time: '08:15' })
    ok('E9 encaixe antes da abertura da loja → BAD_SLOT', !r.ok && /BAD_SLOT/.test(r.err), errcode(r.err))
    r = encaixe(BARBA.uid, { barber: BARBA.uid, ref: refAccount(CLI.uid), day: TUE, time: '19:40', svc: `array[${SVC45}]::bigint[]` })  // 19:40+45 > 20:00
    ok('E9 encaixe que estoura o fechamento da loja → BAD_SLOT', !r.ok && /BAD_SLOT/.test(r.err), errcode(r.err))

    // E10 — serviços inválidos
    for (const [ids, label] of [['array[]::bigint[]', 'vazio'], [`array[${SVC45},${SVC45}]::bigint[]`, 'duplicado'], [`array[999999]::bigint[]`, 'inexistente']]) {
      r = encaixe(BARBA.uid, { barber: BARBA.uid, ref: refAccount(CLI.uid), day: TUE, time: '13:07', svc: ids })
      ok(`E10 encaixe serviço ${label} → SERVICE_INVALID`, !r.ok && /SERVICE_INVALID/.test(r.err), errcode(r.err))
    }

    // E11 — p_client_ref malformado → CLIENT_INVALID, nunca 22P02
    const badRefs = [
      [`'"texto"'::jsonb`, 'string'],
      [`'[]'::jsonb`, 'array'],
      [`'null'::jsonb`, 'json null'],
      [`null`, 'sql NULL'],
      [`'{}'::jsonb`, 'objeto vazio'],
      [`jsonb_build_object('mode','x')`, 'mode desconhecido'],
      [`jsonb_build_object('mode','account','id','abc')`, 'id não-UUID'],
      [`jsonb_build_object('mode','account','id','00000000-0000-0000-0000-000000000000')`, 'UUID inexistente'],
    ]
    for (const [ref, label] of badRefs) {
      r = encaixe(BARBA.uid, { barber: BARBA.uid, ref, day: TUE, time: '13:07' })
      ok(`E11 p_client_ref ${label} → CLIENT_INVALID (sem 22P02 cru)`, !r.ok && /CLIENT_INVALID/.test(r.err) && !/22P02/.test(r.err), errcode(r.err))
    }

    // E12 — walk-in inválido
    for (const [ref, label] of [
      [refWalkin(`${PFX} X`, '12345'), 'telefone curto'],
      [refWalkin(`${PFX} X`, '119876543210000'), 'telefone longo'],
      [`jsonb_build_object('mode','walkin','name','   ','phone','11987654321')`, 'nome só espaços'],
      [`jsonb_build_object('mode','walkin','phone','11987654321')`, 'sem nome'],
    ]) {
      r = encaixe(BARBA.uid, { barber: BARBA.uid, ref, day: TUE, time: '13:07' })
      ok(`E12 walk-in ${label} → WALKIN_INVALID`, !r.ok && /WALKIN_INVALID/.test(r.err), errcode(r.err))
    }

    // E12b — p_notes com 2000 chars → cortado em 500, sem erro
    r = encaixe(BARBA.uid, { barber: BARBA.uid, ref: refAccount(CLI.uid), day: TUE, time: '13:07', notes: 'x'.repeat(2000) })
    nid = idOf(r)
    ok('E12b p_notes 2000 chars → appt criado, notes cortado em 500', r.ok && nid && Number(psql(`select length(notes) from public.appointments where id=${nid};`)) === 500, r.ok ? `len=${psql(`select length(notes) from public.appointments where id=${nid};`)}` : ERR(r.err))
    clearAgenda(BARBA.uid, TUE)

    // E13 — barbeiro A cria encaixe para o barbeiro B
    r = encaixe(BARBA.uid, { barber: BARBB.uid, ref: refAccount(CLI.uid), day: TUE, time: '13:07' })
    ok('E13 barbeiro A cria encaixe p/ barbeiro B → NOT_ALLOWED', !r.ok && /NOT_ALLOWED/.test(r.err), errcode(r.err))

    // E14 — admin / vendas criam encaixe para o barbeiro B
    r = encaixe(ADM.uid, { barber: BARBB.uid, ref: refAccount(CLI.uid), day: TUE, time: '13:07' })
    ok('E14 admin cria encaixe p/ barbeiro B → sucesso', r.ok && idOf(r) > 0, r.ok ? `#${idOf(r)}` : ERR(r.err))
    clearAgenda(BARBB.uid, TUE)
    r = encaixe(VEND.uid, { barber: BARBB.uid, ref: refAccount(CLI.uid), day: TUE, time: '13:07' })
    ok('E14 vendas cria encaixe p/ barbeiro B → sucesso (D-1b-7)', r.ok && idOf(r) > 0, r.ok ? `#${idOf(r)}` : ERR(r.err))
    clearAgenda(BARBB.uid, TUE)

    // E15 — cliente / anon chamam a RPC
    r = encaixe(CLI.uid, { barber: BARBA.uid, ref: refAccount(CLI.uid), day: TUE, time: '13:07' })
    ok('E15 cliente chama staff_book_encaixe → NOT_STAFF', !r.ok && /NOT_STAFF/.test(r.err), errcode(r.err))
    r = encaixe(null, { barber: BARBA.uid, ref: refAccount(CLI.uid), day: TUE, time: '13:07' })
    ok('E15 anon chama staff_book_encaixe → negado', !r.ok && /NOT_AUTH|permission denied|42501/.test(r.err), ERR(r.err))

    // E16/E17 — notify
    r = encaixe(BARBA.uid, { barber: BARBA.uid, ref: refAccount(CLI.uid), day: TUE, time: '13:07', notify: false })
    nid = idOf(r)
    ok('E16 p_notify=false c/ conta → appt criado, 0 notifs', r.ok && nid && notifsFor(nid) === '(nenhuma)', nid && notifsFor(nid))
    clearAgenda(BARBA.uid, TUE)
    r = encaixe(BARBA.uid, { barber: BARBA.uid, ref: refAccount(CLI.uid), day: TUE, time: '13:07', notify: true })
    nid = idOf(r)
    ok('E17 p_notify=true c/ conta → 1 notif encaixe for_role=client na transação', r.ok && nid && notifsFor(nid) === `client/encaixe/${CLI.uid}`, nid && notifsFor(nid))
    clearAgenda(BARBA.uid, TUE)

    // E18 — encaixe p/ ontem
    r = encaixe(BARBA.uid, { barber: BARBA.uid, ref: refAccount(CLI.uid), day: ONTEM, time: '13:07' })
    ok('E18 encaixe p/ ontem → PAST_DAY', !r.ok && /PAST_DAY/.test(r.err), errcode(r.err))
    // hoje num horário que já passou (só se hoje é dia de expediente e já passou um slot dentro da janela)
    if (DOW_HOJE >= 1 && DOW_HOJE <= 6 && NOW_MIN > 9 * 60 + 30 && NOW_MIN < (DOW_HOJE === 6 ? 18 : 20) * 60) {
      const passT = `${String(Math.floor((NOW_MIN - 60) / 60)).padStart(2, '0')}:${String((NOW_MIN - 60) % 60).padStart(2, '0')}`
      r = encaixe(HYB.uid, { barber: HYB.uid, ref: refAccount(CLI.uid), day: HOJE, time: passT })
      ok(`E18 encaixe hoje num horário que já passou (${passT}) → PAST_DAY`, !r.ok && /PAST_DAY/.test(r.err), errcode(r.err))
    } else {
      console.log('  SKIP E18 (hoje-passado): fora do expediente / cedo demais p/ um slot passado válido')
    }

    // E19 — corrida: 2 encaixes p/ o mesmo horário livre
    const ce = `select public.staff_book_encaixe('${BARBA.uid}', ${refAccount(CLI.uid)}, date '${TUE}', '16:07', array[${SVC45}]::bigint[], null, false);`
    const cf = `select public.staff_book_encaixe('${BARBA.uid}', ${refAccount(CLI2.uid)}, date '${TUE}', '16:07', array[${SVC45}]::bigint[], null, false);`
    const [ea, eb] = await Promise.all([callAsP(BARBA.uid, ce), callAsP(BARBA.uid, cf)])
    const ew = [ea, eb].filter((x) => x.ok).length, et = [ea, eb].filter((x) => !x.ok && /SLOT_TAKEN/.test(x.err)).length
    const erows = psql(`select count(*) from public.appointments where barber_id='${BARBA.uid}' and day=date '${TUE}' and time='16:07' and status in ('pendente','confirmado');`)
    ok('E19 corrida 2 encaixes mesmo horário → 1 ok, 1 SLOT_TAKEN, 1 linha', ew === 1 && et === 1 && erows === '1', `wins=${ew} takens=${et} rows=${erows}`)
    clearAgenda(BARBA.uid, TUE)

    // E20 — encaixe → cancela o que ocupava o gap → novo encaixe entra
    const occ = seedAppt({ barber: BARBA.uid, client: CLI.uid, name: `${PFX} e20`, email: CLI.email, day: TUE, time: '13:00', dur: 45, status: 'confirmado' })
    r = encaixe(BARBA.uid, { barber: BARBA.uid, ref: refAccount(CLI2.uid), day: TUE, time: '13:15', notify: false })
    ok('E20 encaixe sobre gap ocupado → SLOT_TAKEN', !r.ok && /SLOT_TAKEN/.test(r.err), errcode(r.err))
    psql(`update public.appointments set status = 'cancelado' where id = ${occ};`)
    r = encaixe(BARBA.uid, { barber: BARBA.uid, ref: refAccount(CLI2.uid), day: TUE, time: '13:15', notify: false })
    ok('E20 após cancelar o ocupante → encaixe entra (cancelado sai da checagem)', r.ok && idOf(r) > 0, r.ok ? `#${idOf(r)}` : ERR(r.err))
    clearAgenda(BARBA.uid, TUE)

    // E21 — regressão legado: #barberApp INSERT de encaixe direto
    r = tryCallAs(BARBA.uid, `insert into public.appointments (barber_id,services,day,day_label,time,duration,status,is_encaixe,client_name)
      values ('${BARBA.uid}',array['Corte Degradê'],date '${TUE}','x','17:03',45,'confirmado',true,'${PFX} legadoEnc') returning id;`)
    ok('E21 regressão: staff legado INSERT de encaixe direto (barbers_insert_own) → passa', r.ok && Number((r.out.match(/\d+/) || [])[0]) > 0, r.ok ? 'ok' : ERR(r.err))
    clearAgenda(BARBA.uid, TUE)

    // E22 — encaixe cujo p_client_ref (account) é um usuário que TAMBÉM é barbeiro
    r = encaixe(BARBA.uid, { barber: BARBA.uid, ref: refAccount(HYB.uid), day: TUE, time: '13:07' })
    nid = idOf(r)
    ok('E22 encaixe p/ cliente-conta que também é barbeiro → permitido, client_id set', r.ok && nid && apptCol(nid, 'client_id') === HYB.uid, r.ok ? `#${nid}` : ERR(r.err))
    clearAgenda(BARBA.uid, TUE)

    // E23 — pós-cutover documentado (exclusion_violation → SLOT_TAKEN): não aplicável (cutover não rodou)
    const hasExcl = psql(`select count(*) from pg_constraint where conname = 'appointments_no_overlap';`)
    ok('E23 (diferido) exclusion constraint appointments_no_overlap ausente no lab (cutover não aplicado)', hasExcl === '0', `constraints=${hasExcl}`)

    // E24 — corrida walk-in: 2 encaixes concorrentes, mesmo barber+telefone (nome novo) → 1 crm_client
    const wname = `${PFX} Corrida24`, wtel = '11924242424'
    const cw = (cli) => `select public.staff_book_encaixe('${BARBA.uid}', ${refWalkin(wname, wtel)}, date '${TUE}', '${cli}', array[${SVC45}]::bigint[], null, false);`
    const [w1, w2] = await Promise.all([callAsP(BARBA.uid, cw('09:07')), callAsP(BARBA.uid, cw('10:07'))])
    const crmN = psql(`select count(*) from public.crm_clients where barber_id='${BARBA.uid}' and lower(name)=lower('${wname}');`)
    const apptN = psql(`select count(*) from public.appointments where barber_id='${BARBA.uid}' and day=date '${TUE}' and client_name='${wname}' and status in ('pendente','confirmado');`)
    ok('E24 corrida walk-in mesmo barber+telefone → 2 appts, EXATAMENTE 1 crm_client', w1.ok && w2.ok && crmN === '1' && apptN === '2', `crm=${crmN} appts=${apptN} ${w1.ok}/${w2.ok}`)
    clearAgenda(BARBA.uid, TUE)

    // E25 — corrida walk-in: 2 concorrentes, mesmo barber+nome, telefones diferentes → 1 cria, 1 WALKIN_CONFLICT
    const nm = `${PFX} Corrida25`
    const cn = (tel, cli) => `select public.staff_book_encaixe('${BARBA.uid}', ${refWalkin(nm, tel)}, date '${TUE}', '${cli}', array[${SVC45}]::bigint[], null, false);`
    const [n1, n2] = await Promise.all([callAsP(BARBA.uid, cn('11930000001', '09:07')), callAsP(BARBA.uid, cn('11930000002', '10:07'))])
    const okc = [n1, n2].filter((x) => x.ok).length
    const conf = [n1, n2].filter((x) => !x.ok && /WALKIN_CONFLICT/.test(x.err)).length
    const crm25 = psql(`select count(*) from public.crm_clients where barber_id='${BARBA.uid}' and lower(name)=lower('${nm}');`)
    ok('E25 corrida walk-in mesmo nome, telefones diferentes → 1 cria, 1 WALKIN_CONFLICT, 1 crm_client', okc === 1 && conf === 1 && crm25 === '1', `ok=${okc} conflict=${conf} crm=${crm25}`)
    clearAgenda(BARBA.uid, TUE)

    // E26 — walk-in: telefone existe c/ nome X, encaixe manda mesmo telefone c/ nome Y → WALKIN_CONFLICT
    psql(`insert into public.crm_clients (barber_id,name,phone) values ('${BARBA.uid}','${PFX} NomeX','11926000001');`)
    r = encaixe(BARBA.uid, { barber: BARBA.uid, ref: refWalkin(`${PFX} NomeY`, '11926000001'), day: TUE, time: '13:07' })
    ok('E26 telefone existe c/ nome X, encaixe c/ nome Y → WALKIN_CONFLICT', !r.ok && /WALKIN_CONFLICT/.test(r.err), errcode(r.err))
    clearAgenda(BARBA.uid, TUE)

    // E27 — locks: crm|tel + crm|nom + agenda| na MESMA transação, namespaces distintos.
    //   callAs embrulha tudo em begin;…commit; → os advisory xact locks vivem até o commit.
    const lp = tryCallAs(BARBA.uid,
      `select public.staff_book_encaixe('${BARBA.uid}', ${refWalkin(`${PFX} LockProbe`, '11927000001')}, date '${TUE}', '13:07', array[${SVC45}]::bigint[], null, false);
       select count(*)::text from pg_locks where locktype = 'advisory' and pid = pg_backend_pid();`)
    const nLocks = lp.ok ? Number(lp.out.trim().split('\n').pop()) : -1
    ok('E27 walk-in mantém ≥3 advisory locks (crm|tel + crm|nom + agenda|) na mesma transação/pid', nLocks >= 3, `locks=${nLocks}`)
    clearAgenda(BARBA.uid, TUE)

    // E27b — encaixe SUCESSO num dia em que a loja está fechada (domingo) → BARBER_OFF (janela da loja null)
    r = encaixe(HYB.uid, { barber: HYB.uid, ref: refAccount(CLI.uid), day: SUN, time: '13:07' })
    ok('E27b encaixe em domingo (loja fechada, open_hours[0]=null) → BARBER_OFF', !r.ok && /BARBER_OFF/.test(r.err), errcode(r.err))
  }

  // ════════════════ EVIDÊNCIAS ════════════════
  console.log('\n── evidências: pg_proc / grants / secdef / search_path ──')
  const ev = psql(`select p.proname||' | secdef='||p.prosecdef||' | '||coalesce(array_to_string(p.proconfig,','),'-')||' | exec='||
      coalesce((select string_agg(g.rolname,',' order by g.rolname) from aclexplode(p.proacl) a join pg_roles g on g.oid=a.grantee
        where a.privilege_type='EXECUTE' and g.rolname not in ('postgres','supabase_admin')),'(só owner)')
    from pg_proc p where p.pronamespace='public'::regnamespace
      and p.proname in ('_staff_can_book_for','_staff_insert_appointment','staff_reschedule_appointment','staff_book_encaixe')
    order by p.proname;`)
  console.log(ev.split('\n').map((l) => '  ' + l).join('\n'))
  const evOkCore = /_staff_can_book_for \| secdef=true \| search_path="" \| exec=\(só owner\)/.test(ev) && /_staff_insert_appointment \| secdef=true \| search_path="" \| exec=\(só owner\)/.test(ev)
  const evOkRpc = /staff_reschedule_appointment \| secdef=true \| search_path="" \| exec=authenticated/.test(ev) && /staff_book_encaixe \| secdef=true \| search_path="" \| exec=authenticated/.test(ev)
  ok('EV núcleo/helper: secdef + search_path="" + só owner', evOkCore, '')
  ok('EV RPCs: secdef + search_path="" + grant só authenticated', evOkRpc, '')

  const finalCount = psql(`select count(*) from public.appointments;`)
  console.log(`\n${fail === 0 ? '✅ TODOS OS TESTES PASSARAM' : '❌ HÁ FALHAS'} — ${pass} ok / ${fail} falhas   (appointments no lab: ${finalCount})\n`)
}

function limpar() {
  psql(`
    delete from public.notifications where appt_id in (select id from public.appointments where client_name like '${PFX}%')
      or recipient_client_id in (select id from auth.users where email like '${PFX}-%')
      or recipient_barber_id in (select id from auth.users where email like '${PFX}-%');
    delete from public.appointments where client_name like '${PFX}%'
      or client_id in (select id from auth.users where email like '${PFX}-%')
      or barber_id in (select id from auth.users where email like '${PFX}-%');
    delete from public.crm_clients where barber_id in (select id from auth.users where email like '${PFX}-%') or name like '${PFX}%';
    delete from public.clients where id in (select id from auth.users where email like '${PFX}-%');
    delete from public.barbers where id in (select id from auth.users where email like '${PFX}-%');
    delete from auth.users where email like '${PFX}-%';`)
  const c = psql(`select count(*) from public.appointments;`)
  console.log(`(limpeza concluída — appointments no lab: ${c}; os 10 ativos backfillados pela ST-1b.0 permanecem)`)
}

try { await main() } catch (e) { console.error('\nERRO FATAL:', e.stack || e.message); fail++ }
finally { try { limpar() } catch (e) { console.error('limpeza falhou:', e.message) } }
process.exit(fail === 0 ? 0 : 1)
