/**
 * Matriz M1–M24 da escrita de agenda — contra o LAB (localhost:8100 / supabase-db).
 * LOTE NORMAL aplicado; CUTOVER (20260829010000) NÃO aplicado.
 * Cria usuários/dados de teste e limpa no fim. Nada em produção.
 *
 * Uso: node scripts/agenda-lab-matriz.mjs
 */
import { execFileSync, spawn } from 'node:child_process'
import { readFileSync } from 'node:fs'
const LAB = 'http://localhost:8100'
const NATHAN = '745bd1c6-f5b0-412f-9011-07c4d789a80f' // hours null -> horários da loja
const IZAQUE = '29d1d3c8-f681-4b95-bd4c-c7f427de5f75' // seg folga; ter-sáb 13-19
const SVC45 = 2 // Corte Degradê 45min
const SVC90 = 16 // Botox capilar 90min
const AK = readFileSync('/home/gabrielparcel/projetos/prime-next/.env.local', 'utf8')
  .split('\n').find((l) => l.startsWith('NEXT_PUBLIC_SUPABASE_ANON_KEY=')).split('=')[1].trim()

const rid = Math.random().toString(36).slice(2, 7)
const PFX = `agtest-${rid}`
let pass = 0, fail = 0
const ok = (n, c, extra = '') => {
  c ? pass++ : fail++
  console.log(`  ${c ? 'OK  ' : 'FAIL'} ${n}${extra ? '  — ' + String(extra).replace(/\s+/g, ' ').slice(0, 160) : ''}`)
}

const PSQL_ARGS = ['exec', '-i', 'supabase-db', 'psql', '-U', 'postgres', '-d', 'postgres', '-qtAX', '-v', 'ON_ERROR_STOP=1']
const psql = (sql) => execFileSync('docker', PSQL_ARGS, { input: sql, encoding: 'utf8' }).trim()

function wrapAs(uid, sql) {
  const claims = uid ? `{"sub":"${uid}","role":"authenticated"}` : `{"role":"anon"}`
  const role = uid ? 'authenticated' : 'anon'
  return `begin;\nset local role ${role};\nset local request.jwt.claims to '${claims}';\n${sql}\ncommit;`
}
const callAs = (uid, sql) => execFileSync('docker', PSQL_ARGS, { input: wrapAs(uid, sql), encoding: 'utf8' }).trim()
function tryCallAs(uid, sql) {
  try { return { ok: true, out: callAs(uid, sql) } }
  catch (e) { return { ok: false, err: ((e.stderr || '') + (e.stdout || '') || e.message).toString() } }
}
function callAsP(uid, sql) {
  return new Promise((resolve) => {
    const p = spawn('docker', PSQL_ARGS)
    let out = '', err = ''
    p.stdout.on('data', (d) => { out += d })
    p.stderr.on('data', (d) => { err += d })
    p.on('close', (code) => resolve(code === 0 ? { ok: true, out: out.trim() } : { ok: false, err: (err + out).toString() }))
    p.stdin.write(wrapAs(uid, sql))
    p.stdin.end()
  })
}

async function signup(tag) {
  const email = `${PFX}-${tag}@prime-lab.local`
  const r = await fetch(`${LAB}/auth/v1/signup`, {
    method: 'POST', headers: { apikey: AK, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password: 'Test-1234!' }),
  })
  const d = await r.json()
  if (!d.user?.id) throw new Error(`signup ${tag} falhou: ${JSON.stringify(d)}`)
  return { email, uid: d.user.id }
}

function nextDow(targetDow) {
  const d = new Date()
  d.setHours(12, 0, 0, 0) // meio-dia local: evita virada de data por fuso
  d.setDate(d.getDate() + 1)
  while (d.getDay() !== targetDow) d.setDate(d.getDate() + 1)
  const p = (n) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`
}
const TUE = nextDow(2)
const MON = nextDow(1)

// grade 45min do Nathan na terça (loja 09:00-20:00): slots :00 :45 :30 :15 a cada 45min
// válidos p/ 45min: 09:00 09:45 10:30 11:15 12:00 12:45 13:30 14:15 15:00 15:45 16:30 17:15 18:00 18:45

async function main() {
  console.log(`\n── Matriz M1–M24 (lab, prefixo ${PFX}, terça base ${TUE}, segunda ${MON}) ──\n`)
  const A = await signup('a'), B = await signup('b'), R = await signup('ref')
  const S = await signup('staff'), NOPROF = await signup('noprof')

  psql(`insert into public.clients (id,email,name) values
    ('${A.uid}','${A.email}','Cliente A'),
    ('${B.uid}','${B.email}','Cliente B'),
    ('${R.uid}','${R.email}','Indicado'),
    ('${S.uid}','${S.email}','Staff User');`)
  psql(`insert into public.barbers (id,name,email,role,is_barber) values
    ('${S.uid}','Staff Teste','${S.email}','barbeiro',true);`)

  // ── M1 — book feliz ──
  let r = tryCallAs(A.uid, `select public.book_appointment('${NATHAN}','${TUE}','10:30', array[${SVC45}]::bigint[]);`)
  const m1id = r.ok ? Number((r.out.match(/\d+/) || [])[0]) : null
  ok('M1 book_appointment feliz', r.ok && m1id > 0, r.err || `id=${m1id}`)
  if (m1id) {
    const [cid, dur, st, enc] = psql(
      `select client_id||'~'||duration||'~'||status||'~'||is_encaixe from public.appointments where id=${m1id};`,
    ).split('~')
    ok('M1 client_id = auth.uid() do chamador (A)', cid === A.uid, cid)
    ok('M1 duração total gravada = 45', dur === '45', dur)
    ok('M1 status=pendente, is_encaixe=false', st === 'pendente' && enc === 'false', `${st}/${enc}`)
    const notif = psql(
      `select for_role||'~'||coalesce(recipient_barber_id::text,'null')||'~'||coalesce(recipient_client_id::text,'null')||'~'||type from public.notifications where appt_id=${m1id};`,
    )
    ok('M1 notificação ao barbeiro criada na transação', notif === `barber~${NATHAN}~null~novo`, notif)
  }

  // ── M2/M3 — client_id nunca é parâmetro ──
  const sig = psql(`select pg_get_function_identity_arguments('public.book_appointment(uuid,date,text,bigint[])'::regprocedure);`)
  ok('M2/M3 book_appointment não recebe client_id (deriva de auth.uid())', !/client/i.test(sig), sig)

  // ── M5 — insert direto anon negado ──
  r = tryCallAs(null, `insert into public.appointments (barber_id,services,day,day_label,time,status,client_name)
    values ('${NATHAN}',array['x'],'${TUE}','x','09:00','pendente','x');`)
  ok('M5 insert direto anon → negado (grant revogado)', !r.ok && /permission denied|42501/i.test(r.err), r.err.split('\n')[0])

  // ── M6 — concorrência real (2 conexões simultâneas, mesmo slot) ──
  const csql = `select public.book_appointment('${NATHAN}','${TUE}','11:15', array[${SVC45}]::bigint[]);`
  const [r6a, r6b] = await Promise.all([callAsP(A.uid, csql), callAsP(B.uid, csql)])
  const wins = [r6a, r6b].filter((x) => x.ok).length
  const takens = [r6a, r6b].filter((x) => !x.ok && /SLOT_TAKEN/.test(x.err)).length
  const cnt6 = psql(`select count(*) from public.appointments where barber_id='${NATHAN}' and day='${TUE}' and time='11:15' and status in ('pendente','confirmado');`)
  ok('M6 concorrência: 1 vence, 1 SLOT_TAKEN, 1 linha', wins === 1 && takens === 1 && cnt6 === '1', `wins=${wins} takens=${takens} rows=${cnt6}`)

  // ── M7 — cancelado libera o slot ──
  const [m6id, m6owner] = psql(`select id||'~'||client_id from public.appointments where barber_id='${NATHAN}' and day='${TUE}' and time='11:15' and status='pendente' limit 1;`).split('~')
  const canc = tryCallAs(m6owner, `select public.cancel_appointment(${m6id});`)
  const other = m6owner === A.uid ? B.uid : A.uid
  r = tryCallAs(other, `select public.book_appointment('${NATHAN}','${TUE}','11:15', array[${SVC45}]::bigint[]);`)
  ok('M7 cancelado libera o slot p/ outro cliente', canc.ok && r.ok && Number((r.out.match(/\d+/) || [])[0]) > 0, canc.err || r.err)

  // ── M9/M10 — reschedule atômico ──
  const resId = Number((callAs(A.uid, `select public.book_appointment('${NATHAN}','${TUE}','13:30', array[${SVC45}]::bigint[]);`).match(/\d+/) || [])[0])
  callAs(B.uid, `select public.book_appointment('${NATHAN}','${TUE}','14:15', array[${SVC45}]::bigint[]);`)
  r = tryCallAs(A.uid, `select public.reschedule_appointment(${resId},'${NATHAN}','${TUE}','14:15', array[${SVC45}]::bigint[]);`)
  const stA = psql(`select status from public.appointments where id=${resId};`)
  ok('M9 reschedule p/ slot ocupado → rollback, antigo intacto', !r.ok && /SLOT_TAKEN/.test(r.err) && stA === 'pendente', `${stA} / ${r.err && r.err.split('\n')[0]}`)
  r = tryCallAs(A.uid, `select public.reschedule_appointment(${resId},'${NATHAN}','${TUE}','15:00', array[${SVC45}]::bigint[]);`)
  const newId = r.ok ? Number((r.out.match(/\d+/) || [])[0]) : null
  const stOld = psql(`select status from public.appointments where id=${resId};`)
  const stNew = newId ? psql(`select status||'~'||client_id from public.appointments where id=${newId};`) : ''
  ok('M10 reschedule p/ livre → novo criado + antigo cancelado (1 txn)', r.ok && newId > 0 && stOld === 'cancelado' && stNew === `pendente~${A.uid}`, `old=${stOld} new=${stNew}`)

  // ── M11 — staff pelo caminho do cliente ──
  r = tryCallAs(S.uid, `select public.book_appointment('${NATHAN}','${TUE}','16:30', array[${SVC45}]::bigint[]);`)
  ok('M11 staff → STAFF_NOT_ALLOWED', !r.ok && /STAFF_NOT_ALLOWED/.test(r.err), r.err && r.err.split('\n').find((l) => /ERROR/.test(l)))

  // ── M12 — public_day_availability sem PII + anon ──
  const ret12 = psql(`select pg_get_function_result('public.public_day_availability(date,bigint[])'::regprocedure);`)
  ok('M12 retorno só (slot text, livre boolean) — zero PII', /slot text/.test(ret12) && /livre boolean/.test(ret12) && !/client|barber|name|email|phone/i.test(ret12), ret12)
  const av = await callAsP(null, `select count(*) filter (where livre) || '/' || count(*) from public.public_day_availability(date '${TUE}', array[${SVC45}]::bigint[]);`)
  ok('M12 anon chama public_day_availability e recebe grade', av.ok && /\/\d+/.test(av.out) && !/^0\//.test(av.out), av.out || av.err)
  const anonSel = tryCallAs(null, `select count(*) from public.appointments;`)
  ok('M12 anon continua sem enxergar linhas de appointments (RLS)', anonSel.ok && anonSel.out === '0', anonSel.out || anonSel.err.split('\n')[0])

  // ── M13 — erros de domínio ──
  // PAST_DAY: "ontem" tem que ser derivado no FUSO DA LOJA, não em `current_date`
  // (que segue o timezone do banco/UTC). O `book_appointment` calcula o dia atual
  // com `shop_settings.timezone`; se o lab virar a meia-noite UTC enquanto ainda
  // é "ontem" no Brasil — ou se `current_date - 1` cair num dia de folga (aí o
  // RPC devolve BAD_SLOT antes de PAST_DAY) — o teste falha à toa.
  // `shop_settings` só é legível por staff (RLS), então a data é resolvida aqui
  // via `psql` (role postgres) e passada como literal. Assim o argumento é
  // sempre "ontem para a loja", em qualquer dia da semana.
  const ONTEM_LOJA = psql(
    `select ((now() at time zone (select timezone from public.shop_settings where id = 1))::date - 1)::text;`,
  )
  const dom = [
    [`select public.book_appointment('${NATHAN}', date '${ONTEM_LOJA}', '10:30', array[${SVC45}]::bigint[]);`, 'PAST_DAY'],
    [`select public.book_appointment('${NATHAN}', current_date + 999, '10:30', array[${SVC45}]::bigint[]);`, 'OUT_OF_WINDOW'],
    [`select public.book_appointment('${NATHAN}','${TUE}','10:31', array[${SVC45}]::bigint[]);`, 'BAD_SLOT'],
    [`select public.book_appointment('${NATHAN}','${TUE}','25:00', array[${SVC45}]::bigint[]);`, 'BAD_SLOT'],
    [`select public.book_appointment('${IZAQUE}','${MON}','13:30', array[${SVC45}]::bigint[]);`, 'BARBER_OFF'],
  ]
  for (const [sql, exp] of dom) {
    const rr = tryCallAs(A.uid, sql)
    ok(`M13 ${exp}`, !rr.ok && new RegExp(exp).test(rr.err), rr.err && (rr.err.split('\n').find((l) => /ERROR/.test(l)) || rr.err.slice(0, 80)))
  }

  // ── M14 — cancelar agendamento de outro cliente ──
  r = tryCallAs(B.uid, `select public.cancel_appointment(${m1id});`) // m1id é de A
  ok('M14 cancel de outro cliente → NOT_FOUND (não vaza posse)', !r.ok && /NOT_FOUND/.test(r.err), r.err && r.err.split('\n').find((l) => /ERROR/.test(l)))

  // ── M15 — validate_coupon endurecido ──
  const vc = psql(`select array_to_string(proconfig,',') from pg_proc where proname='validate_coupon' and pronamespace='public'::regnamespace;`)
  ok('M15 validate_coupon com search_path fixo', /search_path=/.test(vc.replace(/\s/g, '')), vc)

  // ── M17 — 90min ocupa [09:00, 10:30) — dia MON (livre p/ Nathan) ──
  const m17 = Number((callAs(A.uid, `select public.book_appointment('${NATHAN}','${MON}','09:00', array[${SVC90}]::bigint[]);`).match(/\d+/) || [])[0])
  const b0945 = tryCallAs(B.uid, `select public.book_appointment('${NATHAN}','${MON}','09:45', array[${SVC45}]::bigint[]);`)
  const b1030 = tryCallAs(B.uid, `select public.book_appointment('${NATHAN}','${MON}','10:30', array[${SVC45}]::bigint[]);`)
  ok('M17 90min@09:00 bloqueia 09:45 (SLOT_TAKEN)', !b0945.ok && /SLOT_TAKEN/.test(b0945.err), b0945.err && b0945.err.split('\n').find((l) => /ERROR/.test(l)))
  ok('M17 90min@09:00 libera 10:30 (fim do intervalo)', b1030.ok && Number((b1030.out.match(/\d+/) || [])[0]) > 0, `m17=${m17} ${b1030.err || ''}`)

  // ── M18 — grade respeita duração ──
  const last90 = psql(`select coalesce(max(slot),'-') from public.public_day_availability(date '${TUE}', array[${SVC90}]::bigint[]) where livre;`)
  ok('M18 grade 90min (loja 09-20): último slot livre ≤ 18:00', last90 !== '-' && last90 <= '18:00', `último=${last90}`)
  const s1845 = psql(`select count(*) from public.public_day_availability(date '${TUE}', array[${SVC90}]::bigint[]) where slot > '18:00';`)
  ok('M18 nenhum slot após 18:00 p/ 90min', s1845 === '0', s1845)

  // ── M19 — grants mínimos (pg_proc) ──
  const gr = psql(`select p.proname||'='||coalesce((select string_agg(g.rolname,',' order by g.rolname)
      from aclexplode(p.proacl) a join pg_roles g on g.oid=a.grantee
      where a.privilege_type='EXECUTE' and g.rolname not in ('postgres','supabase_admin')),'(só owner)')
    from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in
    ('_hhmm_to_min','_validate_services','_barber_covers','_insert_appointment','_fill_appointment_duration',
     'book_appointment','cancel_appointment','reschedule_appointment','public_day_availability','public_shop_grid')
    order by p.proname;`)
  const grMap = Object.fromEntries(gr.split('\n').map((l) => l.split('=')))
  ok('M19 helpers internos: só owner', ['_hhmm_to_min', '_validate_services', '_barber_covers', '_insert_appointment', '_fill_appointment_duration'].every((h) => grMap[h] === '(só owner)'), JSON.stringify(grMap))
  ok('M19 book/cancel/reschedule: só authenticated', ['book_appointment', 'cancel_appointment', 'reschedule_appointment'].every((h) => grMap[h] === 'authenticated'), JSON.stringify(grMap))
  ok('M19 RPCs públicas: anon,authenticated', grMap['public_day_availability'] === 'anon,authenticated' && grMap['public_shop_grid'] === 'anon,authenticated', JSON.stringify(grMap))

  // ── M20 — validação de serviços (book e availability) ──
  for (const [ids, label] of [['array[]::bigint[]', 'vazio'], [`array[${SVC45},${SVC45}]::bigint[]`, 'duplicado'], [`array[${SVC45},999999]::bigint[]`, 'inválido']]) {
    const rb = tryCallAs(A.uid, `select public.book_appointment('${NATHAN}','${TUE}','17:15', ${ids});`)
    ok(`M20 book serviço ${label} → SERVICE_INVALID`, !rb.ok && /SERVICE_INVALID/.test(rb.err), rb.err && rb.err.split('\n').find((l) => /ERROR/.test(l)))
    const ra = await callAsP(null, `select * from public.public_day_availability(date '${TUE}', ${ids});`)
    ok(`M20 availability serviço ${label} → SERVICE_INVALID`, !ra.ok && /SERVICE_INVALID/.test(ra.err), ra.err && ra.err.split('\n').find((l) => /ERROR/.test(l)))
  }

  // ── M21 — trigger de duração usa slot_min ATUAL ──
  psql(`update public.shop_settings set slot_min = 30 where id = 1;`)
  const d30 = psql(`insert into public.appointments (barber_id,services,day,day_label,time,status,client_name)
    values ('${NATHAN}',array['Corte'],'${TUE}','x','21:00','confirmado','${PFX}-walkin') returning duration;`)
  psql(`update public.shop_settings set slot_min = 45 where id = 1;`)
  const d45 = psql(`insert into public.appointments (barber_id,services,day,day_label,time,duration,status,client_name)
    values ('${NATHAN}',array['Corte'],'${TUE}','x','22:00',60,'confirmado','${PFX}-walkin') returning duration;`)
  ok('M21 insert staff sem duration → slot_min atual (30)', d30 === '30', d30)
  ok('M21 duração explícita (60) preservada', d45 === '60', d45)

  // ── M22 — autenticado sem perfil ──
  r = tryCallAs(NOPROF.uid, `select public.book_appointment('${NATHAN}','${TUE}','12:00', array[${SVC45}]::bigint[]);`)
  const npRows = psql(`select count(*) from public.appointments where client_id='${NOPROF.uid}';`)
  ok('M22 sem linha em clients → PROFILE_REQUIRED, nada inserido', !r.ok && /PROFILE_REQUIRED/.test(r.err) && npRows === '0', `${npRows} / ${r.err && r.err.split('\n').find((l) => /ERROR/.test(l))}`)

  // ── M24 — public_shop_grid não expõe comissao_fiado_na_hora ──
  const grid = psql(`select pg_get_function_result('public.public_shop_grid()'::regprocedure);`)
  ok('M24 public_shop_grid: só slot_min/open_hours/max_advance_days/timezone', !/comissao/i.test(grid) && /slot_min/.test(grid) && /timezone/.test(grid) && /open_hours/.test(grid) && /max_advance_days/.test(grid), grid)
  const gAnon = await callAsP(null, `select slot_min||'|'||timezone from public.public_shop_grid();`)
  ok('M24 anon chama public_shop_grid', gAnon.ok && /45\|America\/Sao_Paulo/.test(gAnon.out), gAnon.out || gAnon.err)

  console.log('\n  — pós-cutover (não aplicável a este lote, marcados como diferidos):')
  console.log('  DIFERIDO M4  insert direto authenticated bloqueado (depende do drop de clients_insert_own/update_own)')
  console.log('  DIFERIDO M8  encaixe sobreposto barrado pela exclusion constraint')
  console.log('  DIFERIDO M16 staff legado inalterado após cutover')
  console.log('  DIFERIDO M23 preflight de serviço legado não-resolvível aborta o cutover')

  console.log(`\n${fail === 0 ? '✅ TODOS OS TESTES PASSARAM' : '❌ HÁ FALHAS'} — ${pass} ok / ${fail} falhas\n`)
}

function limpar() {
  psql(`
    delete from public.notifications where appt_id in (select id from public.appointments where client_name like '${PFX}%' or client_id in (select id from auth.users where email like '${PFX}-%'));
    delete from public.notifications where recipient_client_id in (select id from auth.users where email like '${PFX}-%') or recipient_barber_id in (select id from auth.users where email like '${PFX}-%');
    delete from public.appointments where client_name like '${PFX}%' or client_id in (select id from auth.users where email like '${PFX}-%') or barber_id in (select id from auth.users where email like '${PFX}-%');
    delete from public.referrals where referrer_client_id in (select id from auth.users where email like '${PFX}-%') or referred_client_id in (select id from auth.users where email like '${PFX}-%');
    delete from public.clients where id in (select id from auth.users where email like '${PFX}-%');
    delete from public.barbers where id in (select id from auth.users where email like '${PFX}-%');
    delete from auth.users where email like '${PFX}-%';
    update public.shop_settings set slot_min = 45 where id = 1;`)
  console.log('(limpeza do lab concluída; slot_min restaurado p/ 45)')
}

try { await main() } catch (e) { console.error('\nERRO FATAL:', e.message); fail++ } finally {
  try { limpar() } catch (e) { console.error('limpeza falhou:', e.message) }
}
process.exit(fail === 0 ? 0 : 1)
