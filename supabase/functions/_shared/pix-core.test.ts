import { test } from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { assinaturaValida, calcularValor, cpfValido, dataExpiracao, estadoDoMercadoPago, montarPagamentoPix, taxaELiquido } from "./pix-core.ts";

const CAT = { "Corte Degradê": 45, "Barba Express": 25, "Primeiro corte": 24.99 };

test("valor: soma os serviços do catálogo e rejeita o que não existe", () => {
  assert.deepEqual(calcularValor(["Corte Degradê", "Barba Express"], CAT, null), { total: 70, bruto: 70, cupomAplicado: false });
  assert.deepEqual(calcularValor(["Primeiro corte"], CAT, null), { total: 24.99, bruto: 24.99, cupomAplicado: false });
  assert.ok("erro" in calcularValor(["Corte Fantasma"], CAT, null)); assert.ok("erro" in calcularValor([], CAT, null));
});

test("valor: cupom igual ao do site (fixo vira o total, percentual desconta, restrito vale pra um serviço) e nunca aumenta", () => {
  assert.equal((calcularValor(["Corte Degradê"], CAT, { code: "A", type: "valor_fixo", value: 30, services: [] }) as any).total, 30);
  assert.equal((calcularValor(["Corte Degradê", "Barba Express"], CAT, { code: "B", type: "percentual", value: 10, services: null }) as any).total, 63);
  const restrito = { code: "C", type: "percentual", value: 50, services: ["Corte Degradê"] };
  assert.equal((calcularValor(["Corte Degradê"], CAT, restrito) as any).total, 22.5);
  assert.deepEqual(calcularValor(["Corte Degradê", "Barba Express"], CAT, restrito), { total: 70, bruto: 70, cupomAplicado: false });   // cupom restrito não vale pra mais de um serviço
  assert.equal((calcularValor(["Barba Express"], CAT, { code: "D", type: "valor_fixo", value: 99, services: [] }) as any).total, 25);          // nunca cobra mais que o bruto
  assert.equal((calcularValor(["Corte Degradê"], CAT, { code: "E", type: "percentual", value: 50, services: [], active: false }) as any).total, 45);
});

test("CPF: valida os dígitos e recusa sequências repetidas", () => {
  assert.equal(cpfValido("529.982.247-25"), true);
  assert.equal(cpfValido("52998224726"), false); assert.equal(cpfValido("111.111.111-11"), false); assert.equal(cpfValido("123"), false);
});

test("expiração: 30 minutos no mínimo, com fuso -03:00", () => {
  assert.equal(dataExpiracao(new Date("2026-10-20T15:00:00Z"), 30), "2026-10-20T12:30:00.000-03:00");
  assert.equal(dataExpiracao(new Date("2026-10-20T15:00:00Z"), 10), "2026-10-20T12:30:00.000-03:00");   // menos de 30 não existe
});

test("payload do Pix leva o que o Mercado Pago exige", () => {
  const c = montarPagamentoPix({ valor: 45, descricao: "Corte Degradê", email: "a@b.com", nome: "Maria Souza", cpf: "529.982.247-25", referencia: "uuid-1", urlAviso: "https://x/aviso", expira: "2026-10-20T12:30:00.000-03:00" });
  assert.equal(c.payment_method_id, "pix"); assert.equal(c.transaction_amount, 45); assert.equal(c.external_reference, "uuid-1");
  assert.deepEqual(c.payer, { email: "a@b.com", first_name: "Maria", identification: { type: "CPF", number: "52998224725" } });
});

test("assinatura do aviso: aceita a correta, recusa adulterada, ausente ou de outro segredo", async () => {
  const secret = "segredo-de-teste", ts = "1704908010", reqId = "req-123", dataId = "123456";
  const v1 = createHmac("sha256", secret).update(`id:${dataId};request-id:${reqId};ts:${ts};`).digest("hex");
  const base = { secret, xSignature: `ts=${ts},v1=${v1}`, xRequestId: reqId, dataId };
  assert.equal(await assinaturaValida(base), true);
  assert.equal(await assinaturaValida({ ...base, dataId: "999" }), false);
  assert.equal(await assinaturaValida({ ...base, secret: "outro" }), false);
  assert.equal(await assinaturaValida({ ...base, xSignature: `ts=${ts},v1=${"0".repeat(64)}` }), false);
  assert.equal(await assinaturaValida({ ...base, xSignature: null }), false);
  assert.equal(await assinaturaValida({ ...base, secret: "" }), false);
});

test("estado e taxa vindos do Mercado Pago", () => {
  assert.equal(estadoDoMercadoPago("approved"), "aprovado"); assert.equal(estadoDoMercadoPago("pending"), "pendente");
  assert.equal(estadoDoMercadoPago("cancelled"), "vencido"); assert.equal(estadoDoMercadoPago("refunded"), "estornado");
  assert.equal(estadoDoMercadoPago(undefined), "pendente");
  assert.deepEqual(taxaELiquido({ transaction_amount: 45, fee_details: [{ type: "mercadopago_fee", amount: 0.45 }], transaction_details: { net_received_amount: 44.55 } }), { fee: 0.45, net: 44.55 });
  assert.deepEqual(taxaELiquido({ transaction_amount: 45 }), { fee: 0, net: 45 });
});
