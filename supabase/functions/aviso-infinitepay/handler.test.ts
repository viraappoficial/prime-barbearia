import { test } from "node:test";
import assert from "node:assert/strict";
import { tratarAvisoInfinitePay, type Deps } from "./handler.ts";
import { provedorInfinitePay, consultarPagamentoInfinitePay } from "../_shared/provedores.ts";

const ID = "11111111-2222-3333-4444-555555555555";
const aviso = (o: any = {}) => JSON.stringify({ order_nsu: ID, transaction_nsu: "T1", invoice_slug: "S1", amount: 4500, paid_amount: 4500, capture_method: "pix", ...o });

function montar(json: any, linha: any = { id: ID, status: "pendente", appointment_id: 7, amount: 45 }, ok = true) {
  const c: any = { aprovados: [], consultas: [] };
  const deps: Deps = {
    repo: { async cobranca() { return linha; }, async registrarAprovado(id, p, fee, net, pago) { c.aprovados.push({ id, p, fee, net }); return "ok"; } },
    infinitepay: { async consultar(q) { c.consultas.push(q); return { ok, status: ok ? 200 : 500, json }; } },
    agora: () => new Date("2026-10-30T12:00:00Z"),
  };
  return { deps, c };
}

test("pago e valor confere: confirma no InfinitePay e dá baixa", async () => {
  const { deps, c } = montar({ success: true, paid: true, paid_amount: 4500 });
  const r = await tratarAvisoInfinitePay(aviso(), deps);
  assert.deepEqual([r.status, r.body.resultado], [200, "ok"]);
  assert.deepEqual(c.consultas, [{ order_nsu: ID, transaction_nsu: "T1", slug: "S1" }]);
  assert.deepEqual(c.aprovados, [{ id: ID, p: "T1", fee: null, net: null }]);
});
test("não confia no corpo: se o payment_check diz que não pagou, nada muda", async () => {
  const { deps, c } = montar({ success: true, paid: false });
  assert.equal((await tratarAvisoInfinitePay(aviso({ paid_amount: 99999 }), deps)).body.resultado, "pendente");
  assert.equal(c.aprovados.length, 0);
});
test("valor pago menor que o cobrado: não dá baixa (o devido vem do banco, não do aviso)", async () => {
  const { deps, c } = montar({ paid: true, paid_amount: 1000 });
  assert.equal((await tratarAvisoInfinitePay(aviso({ amount: 1000, paid_amount: 1000 }), deps)).body.resultado, "valor_incompleto");
  assert.equal(c.aprovados.length, 0);
});
test("order_nsu que não é nosso ou cobrança inexistente: 200 ignorado, sem consultar", async () => {
  const a = montar({ paid: true, paid_amount: 4500 });
  assert.deepEqual((await tratarAvisoInfinitePay(aviso({ order_nsu: "123" }), a.deps)).body, { ignorado: true });
  const b = montar({ paid: true, paid_amount: 4500 }, null);
  assert.deepEqual((await tratarAvisoInfinitePay(aviso(), b.deps)).body, { ignorado: true });
  assert.equal(a.c.consultas.length + b.c.consultas.length, 0);
});
test("já aprovado não consulta de novo; consulta que falha devolve 400 (o InfinitePay reenvia); corpo inválido 400", async () => {
  const ja = montar({}, { id: ID, status: "aprovado", appointment_id: 7, amount: 45 });
  assert.equal((await tratarAvisoInfinitePay(aviso(), ja.deps)).body.resultado, "ja_aprovado"); assert.equal(ja.c.consultas.length, 0);
  assert.equal((await tratarAvisoInfinitePay(aviso(), montar({}, undefined, false).deps)).status, 400);
  assert.equal((await tratarAvisoInfinitePay("não é json", montar({}).deps)).status, 400);
  assert.equal((await tratarAvisoInfinitePay(aviso({ transaction_nsu: "" }), montar({}).deps)).status, 400);
});
test("provedor: cria o link em centavos com order_nsu e webhook; token só se existir", async () => {
  const chamadas: any[] = [];
  const f = async (url: string, init: any) => { chamadas.push({ url, init }); return { ok: true, status: 200, json: async () => ({ link: "https://checkout.infinitepay.io/x", slug: "S9" }) }; };
  const e: any = { valor: 45.5, descricao: "Prime Barbearia - Corte", email: "a@b.com", nome: "Ana Souza", cpf: "", referencia: ID, urlAviso: "https://x/aviso", expira: "" };
  const r = await provedorInfinitePay({ handle: "$primebarbearia", urlRetorno: "https://site/ok", fetch: f }).criarPix(e, "k");
  assert.deepEqual([r.ok, r.ticket_url, r.id, r.qr_code], [true, "https://checkout.infinitepay.io/x", "S9", undefined]);
  const corpo = JSON.parse(chamadas[0].init.body);
  assert.deepEqual([corpo.handle, corpo.order_nsu, corpo.items[0].price, corpo.webhook_url, corpo.redirect_url], ["primebarbearia", ID, 4550, "https://x/aviso", "https://site/ok"]);
  assert.equal(chamadas[0].url, "https://api.infinitepay.io/invoices/public/checkout/links");
  assert.equal(chamadas[0].init.headers.Authorization, undefined);
  await provedorInfinitePay({ handle: "t", token: "TK", fetch: f }).criarPix(e, "k");
  assert.equal(chamadas[1].init.headers.Authorization, "Bearer TK");
  const ruim = await provedorInfinitePay({ handle: "t", fetch: async () => ({ ok: false, status: 401, json: async () => ({ message: "unauthorized" }) }) }).criarPix(e, "k");
  assert.equal(ruim.ok, false);
  const c = await consultarPagamentoInfinitePay({ handle: "$t", fetch: f }, { order_nsu: ID, transaction_nsu: "T", slug: "S" });
  assert.equal(chamadas[2].url, "https://api.infinitepay.io/invoices/public/checkout/payment_check"); assert.equal(JSON.parse(chamadas[2].init.body).handle, "t"); assert.equal(c.ok, true);
});
