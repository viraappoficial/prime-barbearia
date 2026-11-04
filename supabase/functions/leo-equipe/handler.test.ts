import { test } from "node:test";
import assert from "node:assert/strict";
import { atendimentos, financeiro, intervalo } from "./calculos.ts";
import { atender, type Controle, type Deps, type Leitura, type Perfil } from "./handler.ts";

const ADMIN: Perfil = { id: "a", nome: "Gabriel", papel: "admin" }, BARB: Perfil = { id: "b", nome: "Miguel", papel: "barbeiro" }, VEND: Perfil = { id: "v", nome: "Recepção", papel: "vendas" };
const HOJE = "2026-11-04";   // quarta

function montar(over: { ia?: any; limiteDia?: number; teto?: number; gasto?: number; feitas?: number; ligado?: boolean } = {}) {
  const reg: any[] = [];
  const leitura: Leitura = {
    async vendas() { return [{ date: HOJE, value: 45, nota_id: 1, type: null, barber_id: "n" }, { date: HOJE, value: 30, nota_id: 2, type: null, barber_id: "m" }, { date: HOJE, value: 0, nota_id: 3, type: "uso_plano", barber_id: "n" }]; },
    async pagamentos() { return [{ nota_id: 1, method: "pix_qrs", value: 45 }, { nota_id: 2, method: "dinheiro", value: 30 }]; },
    async agendamentos() { return [
      { day: HOJE, time: "09:00", status: "concluido", iniciado_em: null, client_name: "Carlos", services: ["Corte"], barber_id: "n", payment_status: null },
      { day: HOJE, time: "15:00", status: "confirmado", iniciado_em: null, client_name: "João", services: ["Corte", "Barba"], barber_id: "n", payment_status: "pago" },
      { day: HOJE, time: "16:00", status: "pendente", iniciado_em: null, client_name: "Ana", services: ["Corte"], barber_id: "m", payment_status: null },
      { day: HOJE, time: "17:00", status: "cancelado", iniciado_em: null, client_name: "Zé", services: ["Corte"], barber_id: "m", payment_status: null }]; },
    async assinaturasAtivas() { return [{ plano_nome: "Plano Prata", client_name: "Rafael", fim: "2026-11-28", barber_id: "n" }]; },
    async nomesBarbeiros() { return { n: "Nathan", m: "Miguel" }; },
  };
  const controle: Controle = {
    async config() { return { ligado: over.ligado ?? true, limiteDia: over.limiteDia ?? 30, tetoMesUsd: over.teto ?? 10 }; },
    async perguntasDoDia() { return over.feitas ?? 0; },
    async gastoDoMes() { return { custoUsd: over.gasto ?? 0, perguntas: 3 }; },
    async registrar(p) { reg.push(p); },
  };
  const deps: Deps = { leitura, controle, ia: over.ia === undefined ? null : over.ia, hoje: HOJE, agoraHm: "14:00" };
  return { deps, reg };
}

test("semana começa na segunda e o mês no dia 1", () => {
  assert.deepEqual(intervalo("semana", HOJE), { de: "2026-11-02", ate: HOJE, rotulo: "Esta semana (02/11 a 04/11)" });
  assert.equal(intervalo("mes", HOJE).de, "2026-11-01");
  assert.equal(intervalo("ontem", HOJE).de, "2026-11-03");
  assert.equal(intervalo("semana", "2026-11-08").de, "2026-11-02");   // domingo ainda é da semana que começou na segunda
});
test("financeiro: soma as vendas, separa por forma e não conta uso de plano como venda", () => {
  const f = financeiro([{ date: HOJE, value: 45, nota_id: 1, type: null, barber_id: "n" }, { date: HOJE, value: 0, nota_id: 3, type: "uso_plano", barber_id: "n" }], [{ nota_id: 1, method: "pix_qrs", value: 45 }]);
  assert.equal(f.total, 45); assert.equal(f.vendas, 1); assert.deepEqual(f.porForma, [{ forma: "pix_qrs", rotulo: "Pix (maquininha)", valor: 45 }]); assert.equal(f.semPagamentoLancado, 0);
});
test("financeiro avisa quando há venda sem forma de pagamento lançada", () => {
  assert.equal(financeiro([{ date: HOJE, value: 50, nota_id: 9, type: null, barber_id: null }], []).semPagamentoLancado, 50);
});
test("atendimentos: não conta cancelados, acha o próximo depois de agora e as faltas", () => {
  const d = atendimentos([
    { day: HOJE, time: "09:00", status: "concluido", iniciado_em: null, client_name: "A", services: [], barber_id: null, payment_status: null },
    { day: HOJE, time: "15:00", status: "confirmado", iniciado_em: null, client_name: "B", services: ["Corte"], barber_id: null, payment_status: "pago" },
    { day: HOJE, time: "13:00", status: "confirmado", iniciado_em: "2026-11-04T13:00:00Z", client_name: "C", services: [], barber_id: null, payment_status: null },
    { day: HOJE, time: "18:00", status: "cancelado", iniciado_em: null, client_name: "D", services: [], barber_id: null, payment_status: null }], "14:00");
  assert.equal(d.total, 3); assert.equal(d.concluidos, 1); assert.equal(d.emAtendimento, 1); assert.equal(d.naFila, 1); assert.equal(d.cancelados, 1);
  assert.equal(d.proximo?.hora, "15:00"); assert.equal(d.proximo?.pagoOnline, true);
});

test("atalho de financeiro responde com os números do sistema, 'como calculei' e botões, sem gastar IA", async () => {
  const { deps, reg } = montar();
  const r = await atender(ADMIN, { atalho: "financeiro_hoje" }, deps);
  assert.equal(r.status, 200);
  assert.match(r.body.texto!, /R\$ 75,00/); assert.match(r.body.texto!, /Pix \(maquininha\) R\$ 45,00/); assert.match(r.body.texto!, /Nathan R\$ 45,00/);
  assert.ok(r.body.como); assert.deepEqual(r.body.botoes?.map((b) => b.tela), ["caixa", "vendas"]);
  assert.deepEqual(reg.map((x) => x.tipo), ["atalho"]);
});
test("atalho de atendimentos mostra o próximo e quantos faltam", async () => {
  const r = await atender(ADMIN, { atalho: "atendimentos_hoje" }, montar().deps);
  assert.match(r.body.texto!, /2 na fila|\*2 na fila\*/); assert.match(r.body.texto!, /Próximo: 15:00 · João/); assert.match(r.body.texto!, /já pagou online/);
});
test("cada perfil só vê os atalhos dele: recepção não vê dinheiro e barbeiro não vê planos", async () => {
  const { deps } = montar();
  assert.match((await atender(VEND, { atalho: "financeiro_hoje" }, deps)).body.texto!, /não consulta/);
  assert.match((await atender(BARB, { atalho: "planos" }, deps)).body.texto!, /não consulta/);
  assert.ok((await atender(VEND, { atalho: "atendimentos_hoje" }, deps)).body.texto!.includes("atendimento"));
  assert.equal((await atender(BARB, { atalho: "financeiro_hoje" }, deps)).body.texto!.includes("Por barbeiro"), false);   // só admin vê o comparativo
});
test("sem login ou sem perfil da equipe não responde nada", async () => {
  assert.equal((await atender(null, { atalho: "planos" }, montar().deps)).status, 401);
});
test("pergunta livre: só admin, e só com a IA configurada", async () => {
  assert.match((await atender(BARB, { pergunta: "e a semana?" }, montar().deps)).body.texto!, /só para admin/);
  assert.match((await atender(ADMIN, { pergunta: "e a semana?" }, montar().deps)).body.texto!, /ainda não foi configurado/);
  assert.equal((await atender(ADMIN, { pergunta: "  " }, montar().deps)).status, 400);
});
test("limite diário e teto mensal travam a pergunta livre, mas não os atalhos", async () => {
  const ia = { async responder() { throw new Error("não devia chamar"); } };
  assert.match((await atender(ADMIN, { pergunta: "oi" }, montar({ ia, feitas: 30 }).deps)).body.texto!, /limite de 30 perguntas/);
  assert.match((await atender(ADMIN, { pergunta: "oi" }, montar({ ia, gasto: 10 }).deps)).body.texto!, /teto de gasto/);
  assert.match((await atender(ADMIN, { atalho: "planos" }, montar({ ia, gasto: 99, feitas: 99 }).deps)).body.texto!, /1 plano ativo/);
});
test("desligado: nada responde", async () => {
  assert.match((await atender(ADMIN, { atalho: "planos" }, montar({ ligado: false }).deps)).body.texto!, /desligado/);
});
test("pergunta livre: a IA chama a ferramenta, o sistema faz a conta e o consumo é registrado", async () => {
  const chamadas: any[] = [];
  const ia = { async responder(p: any) {
    chamadas.push(p);
    if (chamadas.length === 1) return { stop: "tool_use", content: [{ type: "tool_use", id: "t1", name: "financeiro", input: { periodo: "hoje" } }], uso: { modelo: "m", entrada: 100, saida: 20, cacheLeitura: 0, cacheEscrita: 500, chamadas: 1, custoUsd: 0.001 } };
    const res = JSON.parse(p.mensagens.at(-1).content[0].content);
    return { stop: "end_turn", content: [{ type: "text", text: `Hoje deu ${res.total}.` }], uso: { modelo: "m", entrada: 150, saida: 30, cacheLeitura: 500, cacheEscrita: 0, chamadas: 1, custoUsd: 0.0005 } };
  } };
  const { deps, reg } = montar({ ia });
  const r = await atender(ADMIN, { pergunta: "quanto faturamos hoje?" }, deps);
  assert.equal(r.body.texto, "Hoje deu 75."); assert.equal(r.body.ia, true); assert.deepEqual(r.body.botoes?.map((b) => b.tela), ["caixa", "vendas"]);
  assert.equal(reg.length, 1); assert.equal(reg[0].tipo, "ia"); assert.equal(reg[0].uso.chamadas, 2); assert.equal(reg[0].uso.cacheLeitura, 500); assert.ok(Math.abs(reg[0].uso.custoUsd - 0.0015) < 1e-9);
  assert.match(chamadas[0].system, /SÓ LÊ/); assert.equal(chamadas[0].tools.length, 3);
});
test("IA com erro devolve uma mensagem simples e não registra consumo", async () => {
  const { deps, reg } = montar({ ia: { async responder() { throw new Error("fora do ar"); } } });
  const r = await atender(ADMIN, { pergunta: "oi" }, deps);
  assert.match(r.body.texto!, /Não consegui responder/); assert.equal(reg.length, 0);
});
