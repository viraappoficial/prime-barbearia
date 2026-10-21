import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { tratarAvisoPagBank, type Deps } from "./handler.ts";

const TOKEN = "token-da-conta";
const assinar = (corpo: string) => ({ corpo, xAuthenticityToken: createHash("sha256").update(`${TOKEN}-${corpo}`).digest("hex") });
const AVISO = JSON.stringify({ id: "ORDE_AAAA-1111", reference_id: "uuid-1", charges: [{ status: "PAID" }] });
const PAGO = { id: "ORDE_AAAA-1111", reference_id: "uuid-1", charges: [{ id: "CHAR_1", status: "PAID", paid_at: "2026-10-20T15:10:00.000-03:00", amount: { value: 4500, summary: { total: 4500, paid: 4500, refunded: 0 } } }] };

function montar(pedido: any, linha: any = { id: "uuid-1", status: "pendente", appointment_id: 7 }, ok = true) {
  const chamadas: any = { aprovados: [], estornados: [], consultas: 0 };
  const deps: Deps = {
    token: TOKEN,
    repo: {
      async pagamentoPorReferencia() { return linha; },
      async registrarAprovado(id, provider, fee, net, pagoEm) { chamadas.aprovados.push({ id, provider, fee, net, pagoEm }); return linha?.status === "aprovado" ? "ja_aprovado" : linha?.status === "estornado" ? "ja_estornado" : "ok"; },   // igual à função do banco
      async marcarEstornado(id, app) { chamadas.estornados.push({ id, app }); },
    },
    pagbank: { async consultarPedido() { chamadas.consultas++; return { ok, status: ok ? 200 : 500, json: pedido }; } },
  };
  return { deps, chamadas };
}

test("aviso autêntico de pedido pago: consulta o pedido e registra", async () => {
  const { deps, chamadas } = montar(PAGO);
  const r = await tratarAvisoPagBank(assinar(AVISO), deps);
  assert.equal(r.status, 200); assert.equal(r.body.resultado, "ok"); assert.equal(chamadas.consultas, 1);
  assert.deepEqual(chamadas.aprovados, [{ id: "uuid-1", provider: "ORDE_AAAA-1111", fee: null, net: null, pagoEm: "2026-10-20T15:10:00.000-03:00" }]);
});

test("autenticidade inválida, ausente ou corpo reformatado: 401 e nada muda", async () => {
  const a = montar(PAGO);
  assert.equal((await tratarAvisoPagBank({ ...assinar(AVISO), xAuthenticityToken: "0".repeat(64) }, a.deps)).status, 401);
  assert.equal((await tratarAvisoPagBank({ ...assinar(AVISO), xAuthenticityToken: null }, a.deps)).status, 401);
  assert.equal((await tratarAvisoPagBank({ corpo: AVISO.replace("{", "{ "), xAuthenticityToken: assinar(AVISO).xAuthenticityToken }, a.deps)).status, 401);   // um espaço a mais muda o hash
  assert.equal(a.chamadas.consultas, 0); assert.equal(a.chamadas.aprovados.length, 0);
});

test("não confia no corpo do aviso: se o PagBank ainda diz WAITING, não marca como pago", async () => {
  const { deps, chamadas } = montar({ ...PAGO, charges: [{ status: "WAITING" }] });
  const r = await tratarAvisoPagBank(assinar(AVISO), deps);
  assert.equal(r.body.resultado, "pendente"); assert.equal(chamadas.aprovados.length, 0);
});

test("aviso repetido, formato pós-transacional, pedido que não é nosso e consulta que falha", async () => {
  const rep = montar(PAGO, { id: "uuid-1", status: "aprovado", appointment_id: 7 });
  assert.equal((await tratarAvisoPagBank(assinar(AVISO), rep.deps)).body.resultado, "ja_aprovado");
  const pos = montar(PAGO);
  assert.deepEqual((await tratarAvisoPagBank(assinar(JSON.stringify({ notificationCode: "X", notificationType: "transaction" })), pos.deps)).body, { ignorado: true });
  assert.deepEqual((await tratarAvisoPagBank(assinar(AVISO), montar(PAGO, null).deps)).body, { ignorado: true });
  assert.equal((await tratarAvisoPagBank(assinar(AVISO), montar(PAGO, undefined, false).deps)).status, 502);
  assert.equal((await tratarAvisoPagBank(assinar("isto nao e json"), montar(PAGO).deps)).status, 400);
});

test("devolução feita no PagBank (pedido segue PAID, valor devolvido > 0) marca estornado uma vez só", async () => {
  const dev = { ...PAGO, charges: [{ status: "PAID", amount: { summary: { total: 4500, paid: 4500, refunded: 4500 } } }] };
  const a = montar(dev, { id: "uuid-1", status: "aprovado", appointment_id: 7 });
  assert.equal((await tratarAvisoPagBank(assinar(AVISO), a.deps)).body.resultado, "estornado");
  assert.deepEqual(a.chamadas.estornados, [{ id: "uuid-1", app: 7 }]); assert.equal(a.chamadas.aprovados.length, 0);
  const jaEstornado = montar(dev, { id: "uuid-1", status: "estornado", appointment_id: 7 });
  assert.equal((await tratarAvisoPagBank(assinar(AVISO), jaEstornado.deps)).body.resultado, "ja_estornado");
  assert.equal(jaEstornado.chamadas.estornados.length, 0);
});
