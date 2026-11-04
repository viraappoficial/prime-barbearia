import { test } from "node:test";
import assert from "node:assert/strict";
import { criarPagamentoPlano, type Deps, type Repo } from "./handler.ts";

const BARB = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
function montar(over: { cliente?: any; plano?: any; barbeiro?: boolean; assErro?: string; provOk?: boolean } = {}) {
  const e = { cobrancas: new Map<string, any>(), assinaturas: [] as any[], chamadas: [] as any[] };
  const repo: Repo = {
    async cliente() { return over.cliente === undefined ? { id: "u1", name: "Rafael Souza", phone: "(44) 99123-4567", email: "r@x.com" } : over.cliente; },
    async plano() { return over.plano === undefined ? { id: 2, nome: "Plano Prata", valor: 189.9, ativo: true } : over.plano; },
    async barbeiroExiste() { return over.barbeiro !== false; },
    async criarAssinatura(a) { if (over.assErro) throw new Error(over.assErro); e.assinaturas.push(a); return 55; },
    async inserirCobranca(c) { e.cobrancas.set(c.id, { ...c, status: "pendente" }); },
    async atualizarCobranca(id, patch) { Object.assign(e.cobrancas.get(id), patch); },
  };
  const deps: Deps = { repo, urlAviso: "https://x/aviso", novoId: () => "11111111-1111-4111-8111-111111111111", agora: () => new Date("2026-11-04T12:00:00Z"),
    provedor: { async criarPix(entrada, chave) { e.chamadas.push({ entrada, chave }); return over.provOk === false ? { ok: false, status: 500, erro: "x" } : { ok: true, status: 200, id: "slug1", ticket_url: "https://checkout/abc" }; } } };
  return { e, deps };
}

test("cria o pedido com o valor do plano no banco e devolve o link de pagamento", async () => {
  const { e, deps } = montar();
  const r = await criarPagamentoPlano("u1", { plano_id: 2, barber_id: BARB }, deps);
  assert.equal(r.status, 200); assert.equal(r.body.ticket_url, "https://checkout/abc"); assert.equal(r.body.amount, 189.9);
  assert.equal(e.chamadas[0].entrada.valor, 189.9); assert.equal(e.chamadas[0].entrada.referencia, "11111111-1111-4111-8111-111111111111");
  assert.deepEqual(e.assinaturas[0], { plano_id: 2, phone: "44991234567", name: "Rafael Souza", client_id: "u1", barber_id: BARB });
  assert.equal(e.cobrancas.get("11111111-1111-4111-8111-111111111111").provider_payment_id, "slug1");
});
test("sem login não cria nada", async () => {
  const { e, deps } = montar();
  assert.equal((await criarPagamentoPlano(null, { plano_id: 2, barber_id: BARB }, deps)).status, 401);
  assert.equal(e.assinaturas.length, 0);
});
test("valor enviado pelo navegador é ignorado e pedido malformado é recusado", async () => {
  const { e, deps } = montar();
  const r = await criarPagamentoPlano("u1", { plano_id: 2, barber_id: BARB, valor: 1 } as any, deps);
  assert.equal(r.body.amount, 189.9); assert.equal(e.chamadas[0].entrada.valor, 189.9);
  assert.equal((await criarPagamentoPlano("u1", { plano_id: "x", barber_id: BARB }, deps)).status, 400);
  assert.equal((await criarPagamentoPlano("u1", { plano_id: 2, barber_id: "nao-uuid" }, deps)).status, 400);
});
test("cliente sem telefone, plano desativado e barbeiro inexistente são recusados", async () => {
  assert.equal((await criarPagamentoPlano("u1", { plano_id: 2, barber_id: BARB }, montar({ cliente: { id: "u1", name: "A", phone: "123", email: null } }).deps)).body.erro, "telefone_obrigatorio");
  assert.equal((await criarPagamentoPlano("u1", { plano_id: 2, barber_id: BARB }, montar({ plano: { id: 2, nome: "P", valor: 10, ativo: false } }).deps)).body.erro, "plano_indisponivel");
  assert.equal((await criarPagamentoPlano("u1", { plano_id: 2, barber_id: BARB }, montar({ barbeiro: false }).deps)).body.erro, "barbeiro_invalido");
});
test("quem já tem plano ativo recebe 409 e nenhuma cobrança é criada", async () => {
  const { e, deps } = montar({ assErro: "o cliente já tem um plano ativo" });
  const r = await criarPagamentoPlano("u1", { plano_id: 2, barber_id: BARB }, deps);
  assert.equal(r.status, 409); assert.equal(e.cobrancas.size, 0);
});
test("provedor fora do ar cancela a cobrança e avisa", async () => {
  const { e, deps } = montar({ provOk: false });
  const r = await criarPagamentoPlano("u1", { plano_id: 2, barber_id: BARB }, deps);
  assert.equal(r.status, 502); assert.equal(e.cobrancas.get("11111111-1111-4111-8111-111111111111").status, "cancelado");
});
