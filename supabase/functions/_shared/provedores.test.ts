import { test } from "node:test";
import assert from "node:assert/strict";
import { provedorMercadoPago, provedorPagBank } from "./provedores.ts";
import { autenticidadePagBankValida, dataExpiracaoUtc, estadoDoPagBank, extrairPixPagBank, montarPedidoPixPagBank } from "./pix-core.ts";
import { createHash } from "node:crypto";

const ENTRADA = { valor: 45, descricao: "Prime Barbearia - Corte Degradê", email: "maria@x.com", nome: "Maria Souza", cpf: "529.982.247-25", referencia: "uuid-1", urlAviso: "https://x/aviso", expira: "2026-10-20T15:30:00Z" };
const fakeFetch = (resposta: any, ok = true, status = 201) => { const chamadas: any[] = []; return { chamadas, fetch: async (url: string, init: any) => { chamadas.push({ url, init }); return { ok, status, json: async () => resposta }; } }; };

test("PagBank: pedido Pix em centavos, validade em UTC, aviso e CPF só com dígitos", () => {
  const p = montarPedidoPixPagBank(ENTRADA);
  assert.equal(p.reference_id, "uuid-1"); assert.deepEqual(p.customer, { name: "Maria Souza", email: "maria@x.com", tax_id: "52998224725" });
  assert.equal(p.items[0].unit_amount, 4500); assert.deepEqual(p.charges[0].amount, { value: 4500, currency: "BRL" });
  assert.deepEqual(p.charges[0].payment_method, { type: "PIX", pix: { expiration_date: "2026-10-20T15:30:00Z" } });
  assert.deepEqual(p.notification_urls, ["https://x/aviso"]);
  assert.equal(montarPedidoPixPagBank({ ...ENTRADA, expira: "2026-10-20T12:30:00.000-03:00" }).charges[0].payment_method.pix.expiration_date, "2026-10-20T15:30:00Z");   // converte o fuso -03:00
  assert.equal(dataExpiracaoUtc(new Date("2026-10-20T15:00:00.123Z"), 30), "2026-10-20T15:30:00Z");
});

test("PagBank: adaptador chama /orders no sandbox com token e idempotência, e extrai copia e cola e imagem", async () => {
  const f = fakeFetch({ id: "ORDE_1", charges: [{ status: "WAITING", qr_code: { id: "QRCO_1", text: "00020126PIX" }, links: [{ rel: "QRCODE.PNG", href: "https://api/qr.png", media: "image/png" }] }] });
  const r = await provedorPagBank({ token: "tok", sandbox: true, fetch: f.fetch as any }).criarPix(ENTRADA, "pix-uuid-1");
  assert.deepEqual(r, { ok: true, status: 201, id: "ORDE_1", qr_code: "00020126PIX", qr_base64: null, ticket_url: "https://api/qr.png" });
  assert.equal(f.chamadas[0].url, "https://sandbox.api.pagseguro.com/orders");
  assert.equal(f.chamadas[0].init.headers.Authorization, "Bearer tok"); assert.equal(f.chamadas[0].init.headers["x-idempotency-key"], "pix-uuid-1");
  const prod = fakeFetch({ id: "ORDE_2", charges: [{ qr_code: { text: "X" } }] });
  await provedorPagBank({ token: "tok", sandbox: false, fetch: prod.fetch as any }).criarPix(ENTRADA, "k");
  assert.equal(prod.chamadas[0].url, "https://api.pagseguro.com/orders");
});

test("PagBank: recusa do provedor e resposta sem QR viram erro, sem lançar", async () => {
  const a = await provedorPagBank({ token: "t", sandbox: true, fetch: fakeFetch({ error_messages: [{ code: "40002" }] }, false, 400).fetch as any }).criarPix(ENTRADA, "k");
  assert.equal(a.ok, false); assert.equal(a.status, 400);
  const b = await provedorPagBank({ token: "t", sandbox: true, fetch: fakeFetch({ id: "ORDE_3", charges: [{ status: "WAITING" }] }).fetch as any }).criarPix(ENTRADA, "k");
  assert.equal(b.ok, false);
  assert.equal(extrairPixPagBank(null), null);
});

test("Mercado Pago continua funcionando pelo mesmo contrato", async () => {
  const f = fakeFetch({ id: 998877, point_of_interaction: { transaction_data: { qr_code: "000201", qr_code_base64: "iVBOR", ticket_url: "https://mp/t" } } });
  const r = await provedorMercadoPago({ token: "mp", fetch: f.fetch as any }).criarPix({ ...ENTRADA, expira: "2026-10-20T12:30:00.000-03:00" }, "pix-1");
  assert.deepEqual(r, { ok: true, status: 201, id: "998877", qr_code: "000201", qr_base64: "iVBOR", ticket_url: "https://mp/t" });
  assert.equal(f.chamadas[0].url, "https://api.mercadopago.com/v1/payments"); assert.equal(f.chamadas[0].init.headers["X-Idempotency-Key"], "pix-1");
});

test("autenticidade do PagBank: SHA-256 de token-corpo; estados", async () => {
  const corpo = '{"id":"ORDE_1"}', token = "tok";
  const h = createHash("sha256").update(`${token}-${corpo}`).digest("hex");
  assert.equal(await autenticidadePagBankValida({ token, corpo, xAuthenticityToken: h }), true);
  assert.equal(await autenticidadePagBankValida({ token, corpo, xAuthenticityToken: h.toUpperCase() }), true);
  assert.equal(await autenticidadePagBankValida({ token, corpo: corpo + " ", xAuthenticityToken: h }), false);
  assert.equal(await autenticidadePagBankValida({ token: "", corpo, xAuthenticityToken: h }), false);
  assert.equal(estadoDoPagBank("PAID"), "aprovado"); assert.equal(estadoDoPagBank("WAITING"), "pendente");
  assert.equal(estadoDoPagBank("DECLINED"), "vencido"); assert.equal(estadoDoPagBank("CANCELED"), "vencido"); assert.equal(estadoDoPagBank(undefined), "pendente");
});
