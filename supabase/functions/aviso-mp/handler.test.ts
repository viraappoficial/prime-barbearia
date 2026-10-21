import { test } from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { tratarAviso, type Deps } from "./handler.ts";

const SEGREDO = "segredo-de-teste";
const assinar = (dataId: string, reqId = "req-1", ts = "1704908010") => ({ dataId, xRequestId: reqId, xSignature: `ts=${ts},v1=${createHmac("sha256", SEGREDO).update(`id:${dataId};request-id:${reqId};ts:${ts};`).digest("hex")}`, tipo: "payment" });

function montar(pg: any, linha: any = { id: "uuid-1", status: "pendente", appointment_id: 7 }, mpOk = true) {
  const chamadas: any = { aprovados: [], estornados: [], consultas: 0 };
  const deps: Deps = {
    secret: SEGREDO,
    repo: {
      async pagamentoPorReferencia() { return linha; },
      async registrarAprovado(id, provider, fee, net, pagoEm) { chamadas.aprovados.push({ id, provider, fee, net, pagoEm }); return linha?.status === "aprovado" ? "ja_aprovado" : "ok"; },
      async marcarEstornado(id, app) { chamadas.estornados.push({ id, app }); },
    },
    mp: { async buscarPagamento() { chamadas.consultas++; return { ok: mpOk, status: mpOk ? 200 : 500, json: pg }; } },
  };
  return { deps, chamadas };
}
const APROVADO = { id: 998877, status: "approved", external_reference: "uuid-1", transaction_amount: 45, date_approved: "2026-10-20T15:10:00.000-03:00", fee_details: [{ type: "mercadopago_fee", amount: 0.45 }], transaction_details: { net_received_amount: 44.55 } };

test("aviso válido de pagamento aprovado: consulta a API e registra com a taxa real", async () => {
  const { deps, chamadas } = montar(APROVADO);
  const r = await tratarAviso(assinar("998877"), deps);
  assert.equal(r.status, 200); assert.equal(r.body.resultado, "ok"); assert.equal(chamadas.consultas, 1);
  assert.deepEqual(chamadas.aprovados, [{ id: "uuid-1", provider: "998877", fee: 0.45, net: 44.55, pagoEm: "2026-10-20T15:10:00.000-03:00" }]);
});

test("assinatura inválida ou ausente: 401, não consulta nada e nada muda", async () => {
  const a = montar(APROVADO);
  assert.equal((await tratarAviso({ ...assinar("998877"), xSignature: "ts=1,v1=" + "0".repeat(64) }, a.deps)).status, 401);
  assert.equal((await tratarAviso({ ...assinar("998877"), xSignature: null }, a.deps)).status, 401);
  assert.equal((await tratarAviso({ ...assinar("998877"), dataId: "111" }, a.deps)).status, 401);   // corpo trocado depois de assinado
  assert.equal(a.chamadas.consultas, 0); assert.equal(a.chamadas.aprovados.length, 0);
});

test("aviso repetido não duplica: a função do banco devolve ja_aprovado", async () => {
  const { deps, chamadas } = montar(APROVADO, { id: "uuid-1", status: "aprovado", appointment_id: 7 });
  const r = await tratarAviso(assinar("998877"), deps);
  assert.equal(r.status, 200); assert.equal(r.body.resultado, "ja_aprovado"); assert.equal(chamadas.aprovados.length, 1);
});

test("não confia no corpo do aviso: o que vale é o status consultado na API", async () => {
  const { deps, chamadas } = montar({ ...APROVADO, status: "pending" });
  const r = await tratarAviso(assinar("998877"), deps);
  assert.equal(r.body.resultado, "pendente"); assert.equal(chamadas.aprovados.length, 0);
});

test("outros tópicos e pagamentos que não são nossos: 200 e ignora; consulta que falha: 502 pra o Mercado Pago reenviar", async () => {
  const a = montar(APROVADO);
  assert.deepEqual((await tratarAviso({ ...assinar("998877"), tipo: "merchant_order" }, a.deps)).body, { ignorado: true });
  const b = montar(APROVADO, null);
  assert.deepEqual((await tratarAviso(assinar("998877"), b.deps)).body, { ignorado: true });
  const c = montar(APROVADO, undefined, false);
  assert.equal((await tratarAviso(assinar("998877"), c.deps)).status, 502);
});

test("estorno feito no painel do Mercado Pago marca estornado uma vez só", async () => {
  const { deps, chamadas } = montar({ ...APROVADO, status: "refunded" }, { id: "uuid-1", status: "aprovado", appointment_id: 7 });
  assert.equal((await tratarAviso(assinar("998877"), deps)).body.resultado, "estornado");
  assert.deepEqual(chamadas.estornados, [{ id: "uuid-1", app: 7 }]);
  const jaEstornado = montar({ ...APROVADO, status: "refunded" }, { id: "uuid-1", status: "estornado", appointment_id: 7 });
  await tratarAviso(assinar("998877"), jaEstornado.deps); assert.equal(jaEstornado.chamadas.estornados.length, 0);
});
