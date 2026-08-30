/**
 * ST-H · GATE 1 — matriz SH1–SH31 contra o LAB (localhost:8100 / supabase-db).
 *
 * Aplica as 5 migrations ST-H.1–5 (idempotente), semeia usuários/dados de teste,
 * roda a matriz completa via REST/PostgREST + psql, LIMPA os dados de teste
 * (lab volta a 37 appointments) e deixa as migrations APLICADAS (gate 1 = lab
 * com ST-H). No fim, faz um ciclo rollback → verifica baseline → re-aplica, e
 * despeja as evidências (grants / policies / pg_proc / trigger).
 *
 * Nunca toca produção. Uso: node scripts/sth-gate1-matriz.mjs
 */
import { readFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'

const LAB = 'http://localhost:8100'
const MIG = new URL('../supabase/migrations/', import.meta.url)
const FILES = [
  '20260830000000_barber_role.sql',
  '20260830000100_policies_appointments_crm_via_role.sql',
  '20260830000200_appointments_col_guard.sql',
  '20260830000300_staff_status_rpcs.sql',
  '20260830000400_higiene_grants_staff.sql',
]

const env = Object.fromEntries(
  readFileSync('/home/gabrielparcel/projetos/prime-next/.env.local', 'utf8')
    .split('\n').filter((l) => l.includes('=') && !l.trim().startsWith('#'))
    .map((l) => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim()]),
)
const AK = env.NEXT_PUBLIC_SUPABASE_ANON_KEY
const anon = { apikey: AK, Authorization: `Bearer ${AK}`, 'Content-Type': 'application/json' }
const authed = (t) => ({ apikey: AK, Authorization: `Bearer ${t}`, 'Content-Type': 'application/json' })

const PSQL = ['exec', '-i', 'supabase-db', 'psql', '-U', 'postgres', '-d', 'postgres', '-qtAX', '-v', 'ON_ERROR_STOP=1']
const psql = (s) => execFileSync('docker', PSQL, { input: s, encoding: 'utf8' }).trim()
const psqlFile = (path) => execFileSync('docker', ['exec', '-i', 'supabase-db', 'psql', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-qX'], { input: readFileSync(path, 'utf8'), encoding: 'utf8' })
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const reloadPgrst = async () => { psql("notify pgrst, 'reload schema';"); await sleep(700) }

const rid = Math.random().toString(36).slice(2, 7)
const PFX = `sthg1-${rid}`
let pass = 0, fail = 0
const ok = (n, c, extra = '') => {
  c ? pass++ : fail++
  console.log(`  ${c ? 'OK  ' : 'FAIL'} ${n}${extra ? `  — ${String(extra).replace(/\s+/g, ' ').slice(0, 150)}` : ''}`)
}
const NOW = () => new Date().toISOString()

async function signup(tag) {
  const email = `${PFX}-${tag}@prime-lab.local`
  const r = await fetch(`${LAB}/auth/v1/signup`, { method: 'POST', headers: anon, body: JSON.stringify({ email, password: 'Test-1234!' }) })
  const d = await r.json()
  if (!d.user?.id) throw new Error(`signup ${tag}: ${JSON.stringify(d)}`)
  return { uid: d.user.id, tok: d.access_token, email }
}
async function patch(hdrs, id, body) {
  const r = await fetch(`${LAB}/rest/v1/appointments?id=eq.${id}`, { method: 'PATCH', headers: { ...hdrs, Prefer: 'return=minimal' }, body: JSON.stringify(body) })
  return { status: r.status, msg: (await r.text()).replace(/\s+/g, ' ').trim().slice(0, 160) }
}
async function post(hdrs, table, body) {
  const r = await fetch(`${LAB}/rest/v1/${table}`, { method: 'POST', headers: { ...hdrs, Prefer: 'return=representation' }, body: JSON.stringify(body) })
  const txt = await r.text()
  let json = null; try { json = JSON.parse(txt) } catch { /* */ }
  return { status: r.status, json, msg: txt.replace(/\s+/g, ' ').trim().slice(0, 160) }
}
async function rpc(hdrs, fn, args) {
  const r = await fetch(`${LAB}/rest/v1/rpc/${fn}`, { method: 'POST', headers: hdrs, body: JSON.stringify(args) })
  return { status: r.status, msg: (await r.text()).replace(/\s+/g, ' ').trim().slice(0, 160) }
}
const col = (id, c) => psql(`select ${c}::text from public.appointments where id=${id};`)
const errcode = (m) => (m.match(/CLIENT_[A-Z_]+|STAFF_[A-Z_]+|NOT_[A-Z_]+|BAD_TRANSITION|ALREADY_STARTED|permission denied for column \w+|42501|PGRST\d+/) || ['?'])[0]

// ─── migrations ──────────────────────────────────────────────────────────────
async function applyAll() { for (const f of FILES) psqlFile(new URL(f, MIG).pathname); await reloadPgrst() }

const ROLLBACK_SQL = `
-- ST-H.5
grant insert, update, delete on public.appointments to anon;
grant truncate, trigger, references on public.appointments, public.crm_clients, public.notifications to anon, authenticated;
-- ST-H.4
drop function if exists public.staff_accept_appointment(bigint);
drop function if exists public.staff_start_appointment(bigint);
drop function if exists public.staff_undo_start(bigint);
drop function if exists public.staff_no_show(bigint);
drop function if exists public.staff_cancel_appointment(bigint, text);
drop function if exists public._staff_appt_for_write(bigint, boolean);
-- ST-H.3
drop trigger if exists appointments_guard_update on public.appointments;
drop function if exists public._appointments_guard_update();
revoke update (status, iniciado_em, day, day_label, time, duration, services, discount_price, notes, rating, rating_comment, rating_by, client_rating, client_rating_comment, barber_reply, reminder_sent_at) on public.appointments from authenticated;
grant update on public.appointments to authenticated;
-- ST-H.2
alter policy admin_select_all on public.appointments using (exists (select 1 from public.barbers where barbers.id = auth.uid() and barbers.role = 'admin'));
alter policy admin_update_all on public.appointments using (exists (select 1 from public.barbers where barbers.id = auth.uid() and barbers.role = 'admin'));
alter policy appointments_vendas_insert on public.appointments with check (exists (select 1 from public.barbers where barbers.id = auth.uid() and barbers.role = 'vendas'));
alter policy appointments_vendas_read on public.appointments using (exists (select 1 from public.barbers where barbers.id = auth.uid() and barbers.role = 'vendas'));
alter policy appointments_vendas_update on public.appointments using (exists (select 1 from public.barbers where barbers.id = auth.uid() and barbers.role = 'vendas'));
alter policy crm_clients_admin_select_all on public.crm_clients using (exists (select 1 from public.barbers b where b.id = auth.uid() and b.role = 'admin'));
alter policy crm_clients_vendas_insert on public.crm_clients with check (exists (select 1 from public.barbers where barbers.id = auth.uid() and barbers.role = 'vendas'));
alter policy crm_clients_vendas_read on public.crm_clients using (exists (select 1 from public.barbers where barbers.id = auth.uid() and barbers.role = 'vendas'));
-- ST-H.1
drop function if exists public.barber_role();
`

const CLEAN_SQL = `
delete from public.notifications where appt_id in (select id from public.appointments where client_name like '${PFX}%');
delete from public.appointments where client_name like '${PFX}%';
delete from public.clients  where email like '${PFX}-%';
delete from public.barbers  where email like '${PFX}-%';
delete from auth.users where email like '${PFX}-%';
drop table if exists public._sthg1_probe;
drop trigger if exists _sthg1_probe_trg on public.appointments;
drop function if exists public._sthg1_probe_fn();
drop function if exists public._sthg1_invoker(bigint, text);
`

// ─── seed ────────────────────────────────────────────────────────────────────
let CLI, BARBA, BARBB, VEND, ADM, APPT_A, APPT_B
const baseAppt = (clientUid, barberUid, name, email) =>
  `insert into public.appointments (client_id,barber_id,services,day,day_label,time,duration,status,client_name,client_email,discount_price)
   values (${clientUid ? `'${clientUid}'` : 'null'},'${barberUid}',array['Corte Degradê'],current_date+5,'x','10:30',45,'pendente','${name}',${email ? `'${email}'` : 'null'},80) returning id;`

function resetA() {
  psql(`update public.appointments set
    client_id='${CLI.uid}', barber_id='${BARBA.uid}', services=array['Corte Degradê'],
    day=current_date+5, day_label='x', time='10:30', duration=45, status='pendente',
    is_encaixe=false, iniciado_em=null, rating=null, rating_comment=null, rating_by=null,
    client_rating=null, client_rating_comment=null, barber_reply=null, notes=null,
    coupon_code=null, discount_price=80, reminder_sent_at=null,
    client_name='${PFX} cliA', client_email='${CLI.email}'
   where id=${APPT_A};`)
}
const setStatusA = (s) => psql(`update public.appointments set status='${s}' where id=${APPT_A};`)

async function seed() {
  CLI = await signup('cliA'); BARBA = await signup('barbA'); BARBB = await signup('barbB')
  VEND = await signup('vend'); ADM = await signup('adm')
  psql(`insert into public.clients (id,email,name) values
    ('${CLI.uid}','${CLI.email}','${PFX} cliA');`)
  psql(`insert into public.barbers (id,name,email,role,is_barber) values
    ('${BARBA.uid}','${PFX} BarbA','${BARBA.email}','barbeiro',true),
    ('${BARBB.uid}','${PFX} BarbB','${BARBB.email}','barbeiro',true),
    ('${VEND.uid}','${PFX} Vend','${VEND.email}','vendas',false),
    ('${ADM.uid}','${PFX} Adm','${ADM.email}','admin',false);`)
  APPT_A = psql(baseAppt(CLI.uid, BARBA.uid, `${PFX} cliA`, CLI.email))
  APPT_B = psql(baseAppt(CLI.uid, BARBB.uid, `${PFX} cliB`, CLI.email))
}

// helper: espera bloqueio (>=400) e que a linha NÃO mudou a coluna testada
async function expectBlocked(hdrs, label, body, wantCode = null, pre = null) {
  if (pre) psql(pre)
  const before = col(APPT_A, 'status') + '|' + col(APPT_A, 'discount_price') + '|' + col(APPT_A, 'services') + '|' + col(APPT_A, 'rating') + '|' + col(APPT_A, 'barber_id')
  const r = await patch(hdrs, APPT_A, body)
  const after = col(APPT_A, 'status') + '|' + col(APPT_A, 'discount_price') + '|' + col(APPT_A, 'services') + '|' + col(APPT_A, 'rating') + '|' + col(APPT_A, 'barber_id')
  const blocked = r.status >= 400 && before === after
  ok(label, blocked && (!wantCode || r.msg.includes(wantCode)), `HTTP ${r.status} ${wantCode ? '['+errcode(r.msg)+']' : ''} ${before === after ? '' : '⚠️ ROW CHANGED'}`)
  resetA()
}
async function expectOk(hdrs, label, body, pre = null) {
  if (pre) psql(pre)
  const r = await patch(hdrs, APPT_A, body)
  ok(label, r.status < 300, `HTTP ${r.status} ${r.status >= 300 ? r.msg : ''}`)
  resetA()
}

async function main() {
  console.log(`\n╔══ ST-H GATE 1 — matriz SH1–SH31 (lab, prefixo ${PFX}) ══╗\n`)

  console.log('· aplicando ST-H.1–5 (idempotente) ...')
  await applyAll()
  await seed()
  console.log(`· seed: appt A=${APPT_A} (cliA→barbA), appt B=${APPT_B} (cliA→barbB)\n`)

  // ═══ SH1 — barber_role() por papel ═══
  console.log('── SH1 — barber_role() ──')
  const brl = (uid) => psql(`select coalesce((select public.barber_role()),'<null>') from (select set_config('request.jwt.claims', '{"sub":"${uid}","role":"authenticated"}', true)) _;`)
  // via set_config direto não roda auth.uid(); usar wrapper role+claims:
  const roleAs = (uid) => {
    const claims = uid ? `{"sub":"${uid}","role":"authenticated"}` : `{"role":"anon"}`
    return psql(`begin; set local role ${uid ? 'authenticated' : 'anon'}; set local request.jwt.claims to '${claims}'; select coalesce(public.barber_role(),'<null>'); rollback;`)
  }
  ok('SH1 barbeiro A → barbeiro', roleAs(BARBA.uid) === 'barbeiro', roleAs(BARBA.uid))
  ok('SH1 vendas → vendas', roleAs(VEND.uid) === 'vendas', roleAs(VEND.uid))
  ok('SH1 admin → admin', roleAs(ADM.uid) === 'admin', roleAs(ADM.uid))
  ok('SH1 cliente → <null>', roleAs(CLI.uid) === '<null>', roleAs(CLI.uid))
  let anonRole; try { anonRole = roleAs(null); ok('SH1 anon → <null> (sem permission denied)', anonRole === '<null>', anonRole) }
  catch (e) { ok('SH1 anon → <null> (sem permission denied)', false, e.message) }

  // ═══ SH2 — ST-0 A/B/C/D idêntico (spot-check via REST) ═══
  console.log('\n── SH2 — policies de papel: leitura preservada ──')
  {
    const g = async (t, p) => { const r = await fetch(`${LAB}/rest/v1/${p}`, { headers: authed(t) }); return { s: r.status, b: await r.json() } }
    const admAll = await g(ADM.tok, `appointments?select=id&or=(client_name.like.${PFX}*)`)
    ok('SH2 admin lê agenda (admin_update/select via barber_role)', Array.isArray(admAll.b) && admAll.b.length >= 2, `n=${admAll.b?.length}`)
    const vendAll = await g(VEND.tok, `appointments?select=id&client_name=like.${PFX}*`)
    ok('SH2 vendas lê agenda (appointments_vendas_read via barber_role)', Array.isArray(vendAll.b) && vendAll.b.length >= 2, `n=${vendAll.b?.length}`)
    const barbAsees = await g(BARBA.tok, `appointments?select=id,barber_id&client_name=like.${PFX}*`)
    ok('SH2 barbeiro A lê só a própria (barbers_select_own intacta)', barbAsees.b?.every((x) => x.barber_id === BARBA.uid) && barbAsees.b.length === 1, `n=${barbAsees.b?.length}`)
    const cliSees = await g(CLI.tok, `appointments?select=id&client_name=like.${PFX}*`)
    ok('SH2 cliente lê só as próprias (2)', cliSees.b?.length === 2, `n=${cliSees.b?.length}`)
  }

  // ═══ SH2b — current_user por caminho (sonda efêmera, guard REAL intacto) ═══
  console.log('\n── SH2b — current_user nos caminhos de escrita (sonda efêmera) ──')
  psql(`
    create table public._sthg1_probe (id bigserial primary key, cu text, cr text, su text, tg_op text);
    alter table public._sthg1_probe disable row level security;
    grant insert on public._sthg1_probe to anon, authenticated, service_role;
    grant usage on sequence public._sthg1_probe_id_seq to anon, authenticated, service_role;
    create function public._sthg1_probe_fn() returns trigger language plpgsql set search_path='' as $f$
      begin insert into public._sthg1_probe(cu,cr,su,tg_op) values (current_user,current_role,session_user,tg_op); return new; end $f$;
    create trigger _sthg1_probe_trg before update on public.appointments for each row execute function public._sthg1_probe_fn();
    create function public._sthg1_invoker(p_id bigint, p_status text) returns void language sql security invoker set search_path='' as $f$ update public.appointments set status=p_status where id=p_id $f$;
    revoke execute on function public._sthg1_invoker(bigint,text) from public, anon, authenticated, service_role;
    grant execute on function public._sthg1_invoker(bigint,text) to authenticated;
  `)
  await reloadPgrst()
  const probe = async (label, fn, rx) => {
    const before = Number(psql(`select coalesce(max(id),0) from public._sthg1_probe;`))
    try { await fn() } catch { /* */ }
    const row = psql(`select coalesce(string_agg(cu||'|'||cr||'|'||su,';'),'(nenhuma)') from public._sthg1_probe where id>${before};`)
    ok(`SH2b ${label}`, rx.test(row), row)
    resetA()
  }
  await probe('REST authenticated (barbeiro)', () => patch(authed(BARBA.tok), APPT_A, { status: 'confirmado' }), /^authenticated\|authenticated\|/)
  await probe('REST authenticated (cliente)', () => patch(authed(CLI.tok), APPT_A, { status: 'cancelado' }), /^authenticated\|authenticated\|/)
  await probe('SET ROLE service_role', () => psql(`set role service_role; update public.appointments set discount_price=42 where id=${APPT_A}; reset role;`), /^service_role\|service_role\|/)
  await probe('RPC SECURITY DEFINER (owner)', () => rpc(authed(BARBA.tok), 'staff_accept_appointment', { p_id: APPT_A }), /^postgres\|postgres\|/)
  await probe('psql -U postgres', () => psql(`update public.appointments set status='confirmado' where id=${APPT_A};`), /^postgres\|postgres\|postgres/)
  await probe('RPC SECURITY INVOKER (authed)', () => rpc(authed(BARBA.tok), '_sthg1_invoker', { p_id: APPT_A, p_status: 'confirmado' }), /^authenticated\|authenticated\|/)
  psql(`drop trigger if exists _sthg1_probe_trg on public.appointments; drop function if exists public._sthg1_probe_fn(); drop function if exists public._sthg1_invoker(bigint,text); drop table if exists public._sthg1_probe;`)
  await reloadPgrst()

  // ═══ SH3 — cliente: colunas estruturais/operacionais BLOQUEADAS ═══
  console.log('\n── SH3 — cliente PATCH da própria linha: estrutural/operacional bloqueado ──')
  await expectBlocked(authed(CLI.tok), 'SH3 cliente: discount_price', { discount_price: 0 }, 'CLIENT_COL_FORBIDDEN')
  await expectBlocked(authed(CLI.tok), 'SH3 cliente: services', { services: ['Botox capilar'] }, 'CLIENT_COL_FORBIDDEN')
  await expectBlocked(authed(CLI.tok), 'SH3 cliente: day + time', { day: '2099-01-01', time: '23:45' }, 'CLIENT_COL_FORBIDDEN')
  await expectBlocked(authed(CLI.tok), 'SH3 cliente: day_label', { day_label: 'HACK' }, 'CLIENT_COL_FORBIDDEN')
  await expectBlocked(authed(CLI.tok), 'SH3 cliente: duration', { duration: 5 }, 'CLIENT_COL_FORBIDDEN')
  await expectBlocked(authed(CLI.tok), 'SH3 cliente: notes', { notes: 'x' }, 'CLIENT_COL_FORBIDDEN')
  await expectBlocked(authed(CLI.tok), 'SH3 cliente: iniciado_em', { iniciado_em: NOW() }, 'CLIENT_COL_FORBIDDEN')
  await expectBlocked(authed(CLI.tok), 'SH3 cliente: client_rating', { client_rating: 5 }, 'CLIENT_COL_FORBIDDEN')
  await expectBlocked(authed(CLI.tok), 'SH3 cliente: barber_reply', { barber_reply: 'x' }, 'CLIENT_COL_FORBIDDEN')
  await expectBlocked(authed(CLI.tok), 'SH3 cliente: reminder_sent_at', { reminder_sent_at: NOW() }, 'CLIENT_COL_FORBIDDEN')
  await expectBlocked(authed(CLI.tok), 'SH3 cliente: barber_id (fora do grant → 403)', { barber_id: BARBB.uid })
  await expectBlocked(authed(CLI.tok), 'SH3 cliente: is_encaixe (fora do grant → 403)', { is_encaixe: true })
  await expectBlocked(authed(CLI.tok), 'SH3 cliente: coupon_code (fora do grant → 403)', { coupon_code: 'HACK' })
  await expectBlocked(authed(CLI.tok), 'SH3 cliente: created_at (fora do grant → 403)', { created_at: '2000-01-01T00:00:00Z' })

  // ═══ SH4 — cliente: status para valores proibidos ═══
  console.log('\n── SH4 — cliente PATCH status → valor proibido ──')
  await expectBlocked(authed(CLI.tok), 'SH4 cliente: status → confirmado', { status: 'confirmado' }, 'CLIENT_STATUS_FORBIDDEN')
  await expectBlocked(authed(CLI.tok), 'SH4 cliente: status → concluido', { status: 'concluido' }, 'CLIENT_STATUS_FORBIDDEN')
  await expectBlocked(authed(CLI.tok), 'SH4 cliente: status → nao_compareceu', { status: 'nao_compareceu' }, 'CLIENT_STATUS_FORBIDDEN')

  // ═══ SH5 — cliente cancela o PRÓPRIO ativo ═══
  console.log('\n── SH5 — cliente cancela o próprio agendamento ativo ──')
  await expectOk(authed(CLI.tok), 'SH5 cliente: status → cancelado (de pendente)', { status: 'cancelado' })
  await expectOk(authed(CLI.tok), 'SH5 cliente: status → cancelado (de confirmado)', { status: 'cancelado' }, `update public.appointments set status='confirmado' where id=${APPT_A};`)
  await expectBlocked(authed(CLI.tok), 'SH5b cliente: cancelar de concluido', { status: 'cancelado' }, 'CLIENT_STATUS_FORBIDDEN', `update public.appointments set status='concluido' where id=${APPT_A};`)
  await expectBlocked(authed(CLI.tok), 'SH5b cliente: cancelar de nao_compareceu', { status: 'cancelado' }, 'CLIENT_STATUS_FORBIDDEN', `update public.appointments set status='nao_compareceu' where id=${APPT_A};`)
  {
    // cancelado → cancelado: delta VAZIO (nada muda) → guard passa, no-op. Não é
    // violação: nenhuma coluna foi escrita. O que importa é a linha não mudar.
    setStatusA('cancelado')
    const r = await patch(authed(CLI.tok), APPT_A, { status: 'cancelado' })
    ok('SH5b cliente: cancelar de cancelado → no-op (delta vazio), linha inalterada', col(APPT_A, 'status') === 'cancelado', `HTTP ${r.status}, status=${col(APPT_A, 'status')}`)
    resetA()
  }

  // ═══ SH6 — avaliação one-shot (D-H9) ═══
  console.log('\n── SH6 — cliente avalia o próprio corte concluído (one-shot) ──')
  await expectOk(authed(CLI.tok), 'SH6 cliente: rating=5 + comment + rating_by=cliente (concluido, sem nota)', { rating: 5, rating_comment: 'top', rating_by: 'cliente' }, `update public.appointments set status='concluido' where id=${APPT_A};`)
  await expectBlocked(authed(CLI.tok), 'SH6b cliente: rating em pendente', { rating: 5, rating_by: 'cliente' }, 'CLIENT_RATING_FORBIDDEN')
  await expectBlocked(authed(CLI.tok), 'SH6b cliente: rating em confirmado', { rating: 5, rating_by: 'cliente' }, 'CLIENT_RATING_FORBIDDEN', `update public.appointments set status='confirmado' where id=${APPT_A};`)
  await expectBlocked(authed(CLI.tok), 'SH6c cliente: RE-avaliar (já tem rating)', { rating: 3, rating_by: 'cliente' }, 'CLIENT_RATING_FORBIDDEN', `update public.appointments set status='concluido', rating=5, rating_by='cliente' where id=${APPT_A};`)
  await expectBlocked(authed(CLI.tok), 'SH6d cliente: rating=0', { rating: 0, rating_by: 'cliente' }, 'CLIENT_RATING_FORBIDDEN', `update public.appointments set status='concluido' where id=${APPT_A};`)
  await expectBlocked(authed(CLI.tok), 'SH6d cliente: rating=6', { rating: 6, rating_by: 'cliente' }, 'CLIENT_RATING_FORBIDDEN', `update public.appointments set status='concluido' where id=${APPT_A};`)
  await expectBlocked(authed(CLI.tok), 'SH6d cliente: rating=5 + rating_by=barbeiro', { rating: 5, rating_by: 'barbeiro' }, 'CLIENT_RATING_FORBIDDEN', `update public.appointments set status='concluido' where id=${APPT_A};`)
  await expectBlocked(authed(CLI.tok), 'SH6e cliente: rating=5 SEM rating_by (fica null)', { rating: 5 }, 'CLIENT_RATING_FORBIDDEN', `update public.appointments set status='concluido' where id=${APPT_A};`)
  await expectBlocked(authed(CLI.tok), 'SH6e cliente: rating_comment sozinho (sem rating)', { rating_comment: 'só comentário' }, 'CLIENT_RATING_FORBIDDEN', `update public.appointments set status='concluido' where id=${APPT_A};`)
  await expectBlocked(authed(CLI.tok), 'SH6e cliente: rating_by sozinho', { rating_by: 'cliente' }, 'CLIENT_RATING_FORBIDDEN', `update public.appointments set status='concluido' where id=${APPT_A};`)
  await expectBlocked(authed(CLI.tok), 'SH6e cliente: rating=5 + discount_price=0 (permitida + estrutural)', { rating: 5, rating_by: 'cliente', discount_price: 0 }, 'CLIENT_COL_FORBIDDEN', `update public.appointments set status='concluido' where id=${APPT_A};`)
  await expectBlocked(authed(CLI.tok), 'SH6e cliente: status=cancelado + barber_id (permitida + estrutural → 403 grant)', { status: 'cancelado', barber_id: BARBB.uid })

  // ═══ SH7 — colunas de identidade do cliente ═══
  console.log('\n── SH7 — cliente PATCH client_id / client_name / client_email ──')
  await expectBlocked(authed(CLI.tok), 'SH7 cliente: client_id', { client_id: BARBB.uid })
  await expectBlocked(authed(CLI.tok), 'SH7 cliente: client_name', { client_name: 'X' })
  await expectBlocked(authed(CLI.tok), 'SH7 cliente: client_email', { client_email: 'x@x.com' })

  // ═══ SH8 — barbeiro: conjunto operacional LIBERADO ═══
  console.log('\n── SH8 — barbeiro PATCH da própria agenda: operacional liberado ──')
  await expectOk(authed(BARBA.tok), 'SH8 barbeiro: status → confirmado', { status: 'confirmado' })
  await expectOk(authed(BARBA.tok), 'SH8 barbeiro: iniciado_em', { iniciado_em: NOW() }, `update public.appointments set status='confirmado' where id=${APPT_A};`)
  await expectOk(authed(BARBA.tok), 'SH8 barbeiro: day + day_label + time', { day: '2026-12-24', day_label: 'Qui 24/12', time: '15:00' })
  await expectOk(authed(BARBA.tok), 'SH8 barbeiro: duration', { duration: 60 })
  await expectOk(authed(BARBA.tok), 'SH8 barbeiro: services + discount_price', { services: ['Corte Degradê', 'Barba'], discount_price: 55 })
  await expectOk(authed(BARBA.tok), 'SH8 barbeiro: notes', { notes: 'maquina 1 nas laterais' })
  await expectOk(authed(BARBA.tok), 'SH8 barbeiro: client_rating + comment', { client_rating: 4, client_rating_comment: 'ok' })
  await expectOk(authed(BARBA.tok), 'SH8 barbeiro: barber_reply', { barber_reply: 'valeu!' })
  await expectOk(authed(BARBA.tok), 'SH8 barbeiro: reminder_sent_at', { reminder_sent_at: NOW() })

  // ═══ SH9 — barbeiro: dono/estrutural/avaliação-do-cliente BLOQUEADO ═══
  console.log('\n── SH9 — barbeiro PATCH: estrutural / rating do cliente bloqueado ──')
  await expectBlocked(authed(BARBA.tok), 'SH9 barbeiro: client_id (fora do grant → 403)', { client_id: BARBB.uid })
  await expectBlocked(authed(BARBA.tok), 'SH9 barbeiro: barber_id (fora do grant → 403)', { barber_id: BARBB.uid })
  await expectBlocked(authed(BARBA.tok), 'SH9 barbeiro: is_encaixe (fora do grant → 403)', { is_encaixe: true })
  await expectBlocked(authed(BARBA.tok), 'SH9 barbeiro: coupon_code (fora do grant → 403)', { coupon_code: 'X' })
  await expectBlocked(authed(BARBA.tok), 'SH9 barbeiro: rating (nota do cliente)', { rating: 5 }, 'STAFF_COL_FORBIDDEN')
  await expectBlocked(authed(BARBA.tok), 'SH9 barbeiro: rating_by', { rating_by: 'barbeiro' }, 'STAFF_COL_FORBIDDEN')
  await expectBlocked(authed(BARBA.tok), 'SH9 barbeiro: rating_comment', { rating_comment: 'x' }, 'STAFF_COL_FORBIDDEN')

  // ═══ SH10 — barbeiro B numa linha do barbeiro A ═══
  console.log('\n── SH10 — barbeiro B PATCH numa linha do barbeiro A ──')
  {
    const st = col(APPT_A, 'status')
    const r = await patch(authed(BARBB.tok), APPT_A, { status: 'confirmado' })
    ok('SH10 barbeiro B: linha de A não muda (RLS barbers_select_own)', col(APPT_A, 'status') === st, `HTTP ${r.status}, status=${col(APPT_A, 'status')}`)
    resetA()
  }

  // ═══ SH11 — vendas ═══
  console.log('\n── SH11 — vendas ──')
  await expectOk(authed(VEND.tok), 'SH11 vendas: status → confirmado', { status: 'confirmado' })
  await expectOk(authed(VEND.tok), 'SH11 vendas: notes', { notes: 'x' })
  await expectOk(authed(VEND.tok), 'SH11 vendas: services + discount_price', { services: ['Corte Degradê'], discount_price: 50 })
  await expectBlocked(authed(VEND.tok), 'SH11 vendas: barber_id', { barber_id: BARBB.uid })
  await expectBlocked(authed(VEND.tok), 'SH11 vendas: is_encaixe', { is_encaixe: true })
  await expectBlocked(authed(VEND.tok), 'SH11 vendas: rating', { rating: 5 }, 'STAFF_COL_FORBIDDEN')

  // ═══ SH12 — admin ═══
  console.log('\n── SH12 — admin ──')
  await expectOk(authed(ADM.tok), 'SH12 admin: status + discount_price', { status: 'confirmado', discount_price: 10 })
  await expectOk(authed(ADM.tok), 'SH12 admin: notes', { notes: 'x' })
  await expectOk(authed(ADM.tok), 'SH12 admin: day + day_label + time', { day: '2026-12-24', day_label: 'Qui', time: '16:00' })
  await expectBlocked(authed(ADM.tok), 'SH12 admin: client_id', { client_id: BARBB.uid })
  await expectBlocked(authed(ADM.tok), 'SH12 admin: barber_id', { barber_id: BARBB.uid })
  await expectBlocked(authed(ADM.tok), 'SH12 admin: is_encaixe', { is_encaixe: true })
  await expectBlocked(authed(ADM.tok), 'SH12 admin: rating', { rating: 5 }, 'STAFF_COL_FORBIDDEN')

  // ═══ SH13 / SH26 — RPC SECURITY DEFINER bypassa o guard ═══
  console.log('\n── SH13/SH26 — RPC SECURITY DEFINER (owner) bypassa o guard ──')
  {
    setStatusA('pendente')
    const r = await rpc(authed(BARBA.tok), 'staff_accept_appointment', { p_id: APPT_A })
    ok('SH13 staff_accept_appointment (DEFINER) → confirmado, guard bypassado', r.status < 300 && col(APPT_A, 'status') === 'confirmado', `HTTP ${r.status} ${r.msg}`)
    resetA()
    // link_precadastro continua funcionando (não toca appointments, mas prova DEFINER vivo)
    const lr = await rpc(authed(CLI.tok), 'link_precadastro', {})
    ok('SH26 link_precadastro (DEFINER) ainda executa', lr.status < 300, `HTTP ${lr.status} ${lr.msg}`)
  }

  // ═══ SH14–SH19 — RPCs de status ═══
  console.log('\n── SH14–SH19 — RPCs de status ──')
  {
    setStatusA('pendente')
    const nbefore = Number(psql(`select count(*) from public.notifications where appt_id=${APPT_A};`))
    let r = await rpc(authed(BARBA.tok), 'staff_accept_appointment', { p_id: APPT_A })
    const nafter = Number(psql(`select count(*) from public.notifications where appt_id=${APPT_A} and for_role='client' and type='confirmado';`))
    ok('SH14 staff_accept: pendente→confirmado + 1 notif client/confirmado', r.status < 300 && col(APPT_A, 'status') === 'confirmado' && nafter === nbefore + 1, `HTTP ${r.status}, notif=${nafter}`)

    r = await rpc(authed(BARBA.tok), 'staff_accept_appointment', { p_id: APPT_A })
    ok('SH15 staff_accept de algo não-pendente → BAD_TRANSITION', r.status >= 400 && r.msg.includes('BAD_TRANSITION'), `HTTP ${r.status} [${errcode(r.msg)}]`)
    resetA()

    r = await rpc(authed(BARBB.tok), 'staff_accept_appointment', { p_id: APPT_A })
    ok('SH16 staff_accept de agendamento de OUTRO barbeiro (não-admin) → NOT_FOUND', r.msg.includes('NOT_FOUND'), `HTTP ${r.status} [${errcode(r.msg)}]`)
    r = await rpc(authed(BARBB.tok), 'staff_cancel_appointment', { p_id: APPT_A, p_motivo: 'x' })
    ok('SH16 staff_cancel de OUTRO barbeiro → NOT_FOUND', r.msg.includes('NOT_FOUND'), `HTTP ${r.status} [${errcode(r.msg)}]`)
    resetA()

    setStatusA('confirmado')
    r = await rpc(authed(BARBA.tok), 'staff_start_appointment', { p_id: APPT_A })
    ok('SH17 staff_start → iniciado_em setado', r.status < 300 && col(APPT_A, 'iniciado_em') !== '', `HTTP ${r.status}, iniciado_em=${col(APPT_A, 'iniciado_em')}`)
    r = await rpc(authed(BARBA.tok), 'staff_start_appointment', { p_id: APPT_A })
    ok('SH17 staff_start 2× → ALREADY_STARTED', r.msg.includes('ALREADY_STARTED'), `HTTP ${r.status} [${errcode(r.msg)}]`)
    r = await rpc(authed(BARBA.tok), 'staff_undo_start', { p_id: APPT_A })
    ok('SH17 staff_undo_start → iniciado_em null', r.status < 300 && col(APPT_A, 'iniciado_em') === '', `HTTP ${r.status}`)
    r = await rpc(authed(BARBA.tok), 'staff_undo_start', { p_id: APPT_A })
    ok('SH17 staff_undo_start 2× (nada pra desfazer) → BAD_TRANSITION', r.msg.includes('BAD_TRANSITION'), `HTTP ${r.status} [${errcode(r.msg)}]`)
    resetA()

    setStatusA('confirmado')
    const nb = Number(psql(`select count(*) from public.notifications where appt_id=${APPT_A};`))
    r = await rpc(authed(BARBA.tok), 'staff_no_show', { p_id: APPT_A })
    ok('SH18 staff_no_show → nao_compareceu, SEM notif', r.status < 300 && col(APPT_A, 'status') === 'nao_compareceu' && Number(psql(`select count(*) from public.notifications where appt_id=${APPT_A};`)) === nb, `HTTP ${r.status}`)
    resetA()
    setStatusA('confirmado')
    r = await rpc(authed(BARBA.tok), 'staff_cancel_appointment', { p_id: APPT_A, p_motivo: 'imprevisto' })
    const cancNotif = psql(`select coalesce(string_agg(type||'/'||for_role,','),'-') from public.notifications where appt_id=${APPT_A};`)
    ok('SH18 staff_cancel(dono, motivo) → cancelado + notif cancelado-barbeiro/client', r.status < 300 && col(APPT_A, 'status') === 'cancelado' && cancNotif.includes('cancelado-barbeiro/client'), `HTTP ${r.status}, notif=${cancNotif}`)
    resetA()

    setStatusA('pendente')
    r = await rpc(authed(ADM.tok), 'staff_accept_appointment', { p_id: APPT_A })
    ok('SH19 admin chama staff_accept sobre linha de outro barbeiro → ok', r.status < 300 && col(APPT_A, 'status') === 'confirmado', `HTTP ${r.status} ${r.msg}`)
    resetA()
    setStatusA('pendente')
    r = await rpc(authed(VEND.tok), 'staff_accept_appointment', { p_id: APPT_A })
    ok('SH19 vendas chama staff_accept → ok', r.status < 300 && col(APPT_A, 'status') === 'confirmado', `HTTP ${r.status}`)
    r = await rpc(authed(VEND.tok), 'staff_cancel_appointment', { p_id: APPT_A, p_motivo: 'x' })
    ok('SH19 vendas chama staff_cancel → NOT_FOUND (D4: só dono/admin)', r.msg.includes('NOT_FOUND'), `HTTP ${r.status} [${errcode(r.msg)}]`)
    resetA()

    r = await rpc(authed(CLI.tok), 'staff_accept_appointment', { p_id: APPT_A })
    ok('SH20 cliente chama staff_accept → NOT_STAFF', r.msg.includes('NOT_STAFF'), `HTTP ${r.status} [${errcode(r.msg)}]`)
    resetA()
  }

  // ═══ SH21 — smoke legado STAFF via REST direto ═══
  console.log('\n── SH21 — legado STAFF via REST direto (todos passam) ──')
  await expectOk(authed(BARBA.tok), 'SH21 baAcceptAppt {status:confirmado}', { status: 'confirmado' })
  await expectOk(authed(BARBA.tok), 'SH21 baMarcarNaoCompareceu {status:nao_compareceu}', { status: 'nao_compareceu' }, `update public.appointments set status='confirmado' where id=${APPT_A};`)
  await expectOk(authed(BARBA.tok), 'SH21 baIniciarAtendimento {iniciado_em}', { iniciado_em: NOW() }, `update public.appointments set status='confirmado' where id=${APPT_A};`)
  await expectOk(authed(BARBA.tok), 'SH21 baConfirmRemarcar {day,day_label,time}', { day: '2026-12-24', day_label: 'Qui 24/12', time: '15:00' })
  await expectOk(authed(BARBA.tok), 'SH21 baCartSalvarServico {services,discount_price}', { services: ['Corte Degradê'], discount_price: 40 })
  await expectOk(authed(BARBA.tok), 'SH21 feedback barbeiro {status:concluido,client_rating,client_rating_comment}', { status: 'concluido', client_rating: 5, client_rating_comment: 'cliente tranquilo' }, `update public.appointments set status='confirmado' where id=${APPT_A};`)
  await expectOk(authed(BARBA.tok), 'SH21 baSaveReply {barber_reply}', { barber_reply: 'obrigado!' })
  await expectOk(authed(BARBA.tok), 'SH21 baMarcarLembreteEnviado {reminder_sent_at}', { reminder_sent_at: NOW() })

  // ═══ SH22 — smoke legado CLIENTE via REST direto ═══
  console.log('\n── SH22 — legado CLIENTE via REST direto ──')
  await expectOk(authed(CLI.tok), 'SH22 caDoCancel {status:cancelado}', { status: 'cancelado' })
  await expectOk(authed(CLI.tok), 'SH22 feedback cliente {status:concluido,rating,rating_comment,rating_by} (status já concluido)', { status: 'concluido', rating: 5, rating_comment: 'ótimo', rating_by: 'cliente' }, `update public.appointments set status='concluido' where id=${APPT_A};`)

  // ═══ SH23 — grants ═══
  console.log('\n── SH23 — grants finais ──')
  {
    const brExec = psql(`select string_agg(grantee,',' order by grantee) from information_schema.role_routine_grants where routine_schema='public' and routine_name='barber_role' and privilege_type='EXECUTE';`)
    ok('SH23 barber_role EXECUTE = anon,authenticated,postgres', brExec === 'anon,authenticated,postgres', brExec)
    const staffExec = psql(`select string_agg(distinct grantee,',' order by grantee) from information_schema.role_routine_grants where routine_schema='public' and routine_name like 'staff\\_%' and privilege_type='EXECUTE';`)
    ok('SH23 staff_* EXECUTE = authenticated,postgres (sem anon)', staffExec === 'authenticated,postgres', staffExec)
    const guardSec = psql(`select prosecdef::text||'/'||array_to_string(proconfig,',') from pg_proc where proname='_appointments_guard_update';`)
    ok('SH23 guard = SECURITY INVOKER + search_path=""', guardSec === 'false/search_path=""', guardSec)
    const guardGrant = psql(`select coalesce(string_agg(grantee,','),'(nenhum)') from information_schema.role_routine_grants where routine_schema='public' and routine_name='_appointments_guard_update' and privilege_type='EXECUTE' and grantee in ('anon','authenticated');`)
    ok('SH23 guard SEM grant a anon/authenticated', guardGrant === '(nenhum)', guardGrant)
    const updCols = psql(`select string_agg(column_name,',' order by column_name) from information_schema.role_column_grants where table_name='appointments' and grantee='authenticated' and privilege_type='UPDATE';`)
    const want16 = 'barber_reply,client_rating,client_rating_comment,day,day_label,discount_price,duration,iniciado_em,notes,rating,rating_by,rating_comment,reminder_sent_at,services,status,time'
    ok('SH23 authenticated UPDATE = as 16 colunas (nada estrutural)', updCols === want16, updCols)
    const anonTbl = psql(`select string_agg(privilege_type,',' order by privilege_type) from information_schema.role_table_grants where table_schema='public' and table_name='appointments' and grantee='anon';`)
    ok('SH23 anon em appointments = só SELECT', anonTbl === 'SELECT', anonTbl)
  }

  // ═══ SH24 — TRUNCATE / anon writes ═══
  console.log('\n── SH24 — TRUNCATE authenticated / escrita anon ──')
  {
    const t = (uid, sql) => {
      const claims = uid ? `{"sub":"${uid}","role":"authenticated"}` : `{"role":"anon"}`
      try { psql(`begin; set local role ${uid ? 'authenticated' : 'anon'}; set local request.jwt.claims to '${claims}'; ${sql} rollback;`); return 'OK' }
      catch (e) { return (e.stderr || e.message || '').toString().replace(/\s+/g, ' ').slice(0, 80) }
    }
    ok('SH24 TRUNCATE appointments (authenticated) → negado', /permission denied|must be owner/.test(t(BARBA.uid, 'truncate public.appointments;')), t(BARBA.uid, 'truncate public.appointments;'))
    ok('SH24 INSERT appointments (anon) → negado', /permission denied|violates row-level/.test(t(null, `insert into public.appointments (barber_id,services,day,day_label,time,status,client_name) values ('${BARBA.uid}','{}','2099-01-01','x','10:00','pendente','x');`)), 'anon insert')
    ok('SH24 UPDATE appointments (anon) → negado', /permission denied/.test(t(null, `update public.appointments set status='x' where id=${APPT_A};`)), 'anon update')
  }

  // ═══ SH25 — pg_policy após ST-H.2 ═══
  console.log('\n── SH25 — policies de appointments/crm_clients ──')
  {
    const cnt = psql(`select count(*)::text from pg_policy where polrelid='public.appointments'::regclass;`)
    ok('SH25 appointments: 11 policies (contagem inalterada)', cnt === '11', cnt)
    const usesRole = psql(`select count(*)::text from pg_policy where polrelid in ('public.appointments'::regclass,'public.crm_clients'::regclass) and (pg_get_expr(polqual,polrelid) like '%barber_role()%' or pg_get_expr(polwithcheck,polrelid) like '%barber_role()%');`)
    ok('SH25 8 policies agora usam barber_role()', usesRole === '8', usesRole)
    const stillInline = psql(`select coalesce(string_agg((polrelid::regclass)::text||'.'||polname,','),'-') from pg_policy where polrelid in ('public.appointments'::regclass,'public.crm_clients'::regclass) and (pg_get_expr(polqual,polrelid) ~ 'from barbers|FROM barbers' or pg_get_expr(polwithcheck,polrelid) ~ 'from barbers|FROM barbers');`)
    ok('SH25 nenhuma policy de appointments/crm_clients ainda inlina "from barbers"', stillInline === '-', stillInline)
  }

  // ═══ SH27 — coluna futura (default-deny nas DUAS camadas) ═══
  console.log('\n── SH27 — coluna futura (default-deny) ──')
  {
    psql(`alter table public.appointments add column _sth_teste text;`)
    await reloadPgrst()
    // camada 1: sem grant → PATCH rejeitado no grant
    const rc1 = await patch(authed(CLI.tok), APPT_A, { _sth_teste: 'x' })
    ok('SH27a coluna nova SEM grant: cliente PATCH → bloqueado na camada 1', rc1.status >= 400, `HTTP ${rc1.status} [${errcode(rc1.msg)}]`)
    // camada 2: concede o grant e prova que o TRIGGER também barra (allow-list)
    psql(`grant update (_sth_teste) on public.appointments to authenticated;`)
    await reloadPgrst()
    const rc2 = await patch(authed(CLI.tok), APPT_A, { _sth_teste: 'x' })
    const rb2 = await patch(authed(BARBA.tok), APPT_A, { _sth_teste: 'x' })
    ok('SH27b coluna nova COM grant: cliente PATCH → CLIENT_COL_FORBIDDEN (trigger)', rc2.status === 400 && rc2.msg.includes('CLIENT_COL_FORBIDDEN'), `HTTP ${rc2.status} [${errcode(rc2.msg)}]`)
    ok('SH27b coluna nova COM grant: barbeiro PATCH → STAFF_COL_FORBIDDEN (trigger)', rb2.status === 400 && rb2.msg.includes('STAFF_COL_FORBIDDEN'), `HTTP ${rb2.status} [${errcode(rb2.msg)}]`)
    psql(`alter table public.appointments drop column _sth_teste;`)
    await reloadPgrst()
    resetA()
  }

  // ═══ SH28 — smoke legado CLIENTE ponta a ponta ═══
  console.log('\n── SH28 — smoke legado cliente: INSERT direto + cancelar + avaliar ──')
  {
    const ins = await post(authed(CLI.tok), 'appointments', { client_id: CLI.uid, barber_id: BARBA.uid, services: ['Corte Degradê'], day: '2099-02-02', day_label: 'x', time: '09:00', status: 'pendente', client_name: `${PFX} cliA`, client_email: CLI.email })
    const newId = ins.json?.[0]?.id
    ok('SH28 wizard INSERT direto (clients_insert_own)', ins.status < 300 && !!newId, `HTTP ${ins.status} ${ins.msg}`)
    if (newId) {
      const c = await fetch(`${LAB}/rest/v1/appointments?id=eq.${newId}`, { method: 'PATCH', headers: { ...authed(CLI.tok), Prefer: 'return=minimal' }, body: JSON.stringify({ status: 'cancelado' }) })
      ok('SH28 caDoCancel {status:cancelado}', c.status < 300, `HTTP ${c.status}`)
      psql(`update public.appointments set status='concluido' where id=${newId};`)
      const fb = await fetch(`${LAB}/rest/v1/appointments?id=eq.${newId}`, { method: 'PATCH', headers: { ...authed(CLI.tok), Prefer: 'return=minimal' }, body: JSON.stringify({ status: 'concluido', rating: 5, rating_comment: 'ok', rating_by: 'cliente' }) })
      ok('SH28 feedback cliente {rating,rating_comment,rating_by}', fb.status < 300, `HTTP ${fb.status} ${fb.status >= 300 ? (await fb.text()).slice(0, 80) : ''}`)
      psql(`delete from public.notifications where appt_id=${newId}; delete from public.appointments where id=${newId};`)
    }
  }

  // ═══ SH29 — smoke legado BARBEIRO ponta a ponta ═══
  console.log('\n── SH29 — smoke legado barbeiro: aceitar→iniciar→remarcar→serviço→feedback→reply→lembrete ──')
  {
    setStatusA('pendente')
    const steps = [
      ['aceitar', { status: 'confirmado' }],
      ['iniciar', { iniciado_em: NOW() }],
      ['remarcar in-place', { day: '2026-12-26', day_label: 'Sáb 26/12', time: '11:00' }],
      ['salvar serviço + desconto', { services: ['Corte Degradê', 'Barba'], discount_price: 70 }],
      ['feedback barbeiro', { status: 'concluido', client_rating: 5, client_rating_comment: 'ok' }],
      ['responder avaliação', { barber_reply: 'valeu' }],
      ['marcar lembrete', { reminder_sent_at: NOW() }],
    ]
    let allOk = true
    for (const [lbl, body] of steps) {
      const r = await patch(authed(BARBA.tok), APPT_A, body)
      if (r.status >= 300) { allOk = false; console.log(`     ✗ ${lbl}: HTTP ${r.status} ${r.msg}`) }
    }
    ok('SH29 fluxo completo do #barberApp legado passa', allOk)
    resetA()
  }

  // ═══ SH30 — smoke legado VENDAS ═══
  console.log('\n── SH30 — smoke legado vendas: INSERT + PATCH status; barber_id bloqueado ──')
  {
    const ins = await post(authed(VEND.tok), 'appointments', { barber_id: BARBA.uid, services: ['Corte Degradê'], day: '2099-03-03', day_label: 'x', time: '14:00', status: 'confirmado', client_name: `${PFX} walkin`, is_encaixe: true })
    const vid = ins.json?.[0]?.id
    ok('SH30 vendas INSERT (appointments_vendas_insert)', ins.status < 300 && !!vid, `HTTP ${ins.status} ${ins.msg}`)
    if (vid) {
      const u = await fetch(`${LAB}/rest/v1/appointments?id=eq.${vid}`, { method: 'PATCH', headers: { ...authed(VEND.tok), Prefer: 'return=minimal' }, body: JSON.stringify({ status: 'concluido' }) })
      ok('SH30 vendas PATCH status', u.status < 300, `HTTP ${u.status}`)
      const b = await fetch(`${LAB}/rest/v1/appointments?id=eq.${vid}`, { method: 'PATCH', headers: { ...authed(VEND.tok), Prefer: 'return=minimal' }, body: JSON.stringify({ barber_id: BARBB.uid }) })
      ok('SH30 vendas PATCH barber_id → bloqueado', b.status >= 400, `HTTP ${b.status}`)
      psql(`delete from public.notifications where appt_id=${vid}; delete from public.appointments where id=${vid};`)
    }
  }

  // ═══ SH31 — smoke legado ADMIN ═══
  console.log('\n── SH31 — smoke legado admin: admin_update_all status/discount/notes; client_id/barber_id bloqueado ──')
  await expectOk(authed(ADM.tok), 'SH31 admin PATCH status', { status: 'confirmado' })
  await expectOk(authed(ADM.tok), 'SH31 admin PATCH discount_price', { discount_price: 33 })
  await expectOk(authed(ADM.tok), 'SH31 admin PATCH notes', { notes: 'admin note' })
  await expectBlocked(authed(ADM.tok), 'SH31 admin PATCH client_id → bloqueado', { client_id: BARBB.uid })
  await expectBlocked(authed(ADM.tok), 'SH31 admin PATCH barber_id → bloqueado', { barber_id: BARBB.uid })

  // ═══ SH2 (bis) — ST-0 test:staff-lab regressão ═══
  console.log('\n── regressão ST-0 (test:staff-lab) ──')
  try {
    const out = execFileSync('node', ['scripts/staff-lab-test.mjs'], { cwd: '/home/gabrielparcel/projetos/prime-next', encoding: 'utf8' })
    const failed = (out.match(/❌/g) || []).length
    ok('SH2 test:staff-lab (ST-0 A/B/C/D) sem regressão', failed === 0, `${failed} falha(s)`)
  } catch (e) {
    ok('SH2 test:staff-lab', false, (e.stdout || e.message || '').toString().slice(-200))
  }

  console.log(`\n${fail === 0 ? '✅ GATE 1 — matriz VERDE' : '❌ ' + fail + ' FALHA(S)'} — ${pass} OK / ${fail} FAIL\n`)
}

// ─── ciclo de rollback (prova que reverte) ───────────────────────────────────
async function rollbackCheck() {
  console.log('── ciclo de rollback: reverter → verificar baseline → re-aplicar ──')
  psql(ROLLBACK_SQL)
  await reloadPgrst()
  const noFn = psql(`select count(*)::text from pg_proc where proname in ('barber_role','_appointments_guard_update','staff_accept_appointment','_staff_appt_for_write');`)
  const noTrg = psql(`select count(*)::text from pg_trigger where tgname='appointments_guard_update';`)
  const tblUpd = psql(`select count(*)::text from information_schema.role_table_grants where table_schema='public' and table_name='appointments' and grantee='authenticated' and privilege_type='UPDATE';`)
  const inlineBack = psql(`select count(*)::text from pg_policy where polrelid='public.appointments'::regclass and polname='admin_update_all' and pg_get_expr(polqual,polrelid) ~* 'barbers' and pg_get_expr(polqual,polrelid) !~ 'barber_role';`)
  ok('rollback: funções ST-H removidas', noFn === '0', `pg_proc=${noFn}`)
  ok('rollback: trigger appointments_guard_update removido', noTrg === '0', noTrg)
  ok('rollback: authenticated volta a ter UPDATE tabela-inteira', tblUpd === '1', tblUpd)
  ok('rollback: admin_update_all volta ao EXISTS inline (sem barber_role)', inlineBack === '1', inlineBack)
  console.log('· re-aplicando ST-H.1–5 ...')
  await applyAll()
  const back = psql(`select count(*)::text from pg_trigger where tgname='appointments_guard_update';`)
  ok('re-aplicação: guard de volta', back === '1', back)
}

// ─── evidências finais ──────────────────────────────────────────────────────
function evidencias() {
  console.log('\n╔══ EVIDÊNCIAS (estado final do lab — ST-H aplicada) ══╗\n')
  console.log(psql(`
    \\echo '── pg_proc (ST-H) ──'
    select proname||'  sec='||case when prosecdef then 'DEFINER' else 'INVOKER' end||'  cfg='||coalesce(array_to_string(proconfig,','),'-')
      from pg_proc where proname in ('barber_role','_appointments_guard_update','_staff_appt_for_write','staff_accept_appointment','staff_start_appointment','staff_undo_start','staff_no_show','staff_cancel_appointment') order by proname;
    \\echo ''
    \\echo '── EXECUTE grants (ST-H) ──'
    select routine_name||' → '||string_agg(grantee,',' order by grantee)
      from information_schema.role_routine_grants
      where routine_schema='public' and routine_name in ('barber_role','_appointments_guard_update','staff_accept_appointment','staff_start_appointment','staff_undo_start','staff_no_show','staff_cancel_appointment','_staff_appt_for_write')
        and privilege_type='EXECUTE' group by routine_name order by routine_name;
    \\echo ''
    \\echo '── appointments: grants de tabela ──'
    select grantee||': '||string_agg(privilege_type,',' order by privilege_type)
      from information_schema.role_table_grants where table_schema='public' and table_name='appointments' group by grantee order by grantee;
    \\echo ''
    \\echo '── appointments: UPDATE por coluna (authenticated) ──'
    select string_agg(column_name,', ' order by column_name)
      from information_schema.role_column_grants where table_name='appointments' and grantee='authenticated' and privilege_type='UPDATE';
    \\echo ''
    \\echo '── crm_clients / notifications: grants de tabela ──'
    select table_name||' '||grantee||': '||string_agg(privilege_type,',' order by privilege_type)
      from information_schema.role_table_grants where table_schema='public' and table_name in ('crm_clients','notifications') group by table_name, grantee order by table_name, grantee;
    \\echo ''
    \\echo '── triggers em appointments ──'
    select tgname||'  '||pg_get_triggerdef(oid) from pg_trigger where tgrelid='public.appointments'::regclass and not tgisinternal order by tgname;
    \\echo ''
    \\echo '── policies appointments/crm_clients (USING/CHECK) ──'
    select (polrelid::regclass)::text||' . '||polname||'  '||coalesce(pg_get_expr(polqual,polrelid),'')||coalesce(' | CHECK '||pg_get_expr(polwithcheck,polrelid),'')
      from pg_policy where polrelid in ('public.appointments'::regclass,'public.crm_clients'::regclass) order by 1;
    \\echo ''
    \\echo '── guard: definição ──'
    select pg_get_functiondef('public._appointments_guard_update()'::regprocedure);
    \\echo ''
    \\echo '── appointment count ──'
    select count(*) from public.appointments;
  `))
}

let cleanedCount = null
try {
  await main()
  await rollbackCheck()
} catch (e) {
  console.error('\nERRO:', e.stack || e.message); fail++
} finally {
  try {
    psql(CLEAN_SQL)
    await reloadPgrst()
    cleanedCount = psql(`select count(*)::text from public.appointments;`)
    console.log(`\n(dados de teste removidos — appointments no lab: ${cleanedCount})`)
  } catch (e) { console.error('LIMPEZA FALHOU:', e.message); fail++ }
}
try { evidencias() } catch (e) { console.error('evidências:', e.message) }
console.log(`\n${fail === 0 && cleanedCount === '37' ? '✅ GATE 1 COMPLETO' : '❌ revisar'} — ${pass} OK / ${fail} FAIL · lab=${cleanedCount} appointments\n`)
process.exit(fail === 0 && cleanedCount === '37' ? 0 : 1)
