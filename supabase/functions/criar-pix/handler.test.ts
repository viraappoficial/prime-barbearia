import { test } from "node:test";
import assert from "node:assert/strict";
import { criarPix, type Agendamento, type Deps, type Pagamento, type Repo } from "./handler.ts";

const CPF = "529.982.247-25";
const AGORA = new Date("2026-10-20T15:00:00Z");

function montar(over: { ag?: Partial<Agendamento> | null; mpOk?: boolean; mpStatus?: number; pendente?: Pagamento | null } = {}) {
  const estado = { pagamentos: new Map<string, any>(), agendamento: { payment_status: "nenhum" } as any, chamadasMp: [] as any[], expirou: 0 };
  const ag: Agendamento | null = over.ag === null ? null : { id: 7, status: "pendente", payment_status: "nenhum", services: ["Corte Degradê"], coupon_code: null, client_name: "Maria Souza", client_email: "maria@x.com", day: "2026-12-10", ...over.ag };
  const repo: Repo = {
    async expirar() { estado.expirou++; },
    async agendamento() { return ag; },
    async catalogo() { return { "Corte Degradê": 45, "Barba Express": 25 }; },
    async cupom(code) { return code === "DEZ" ? { code: "DEZ", type: "percentual", value: 10, services: null, active: true } : null; },
    async pagamentoPendente() { return over.pendente ?? null; },
    async inserirPagamento(p) { estado.pagamentos.set(p.id, { ...p, status: "pendente" }); },
    async atualizarPagamento(id, patch) { Object.assign(estado.pagamentos.get(id), patch); },
    async marcarAgendamento(_id, patch) { Object.assign(estado.agendamento, patch); },
  };
  const deps: Deps = {
    repo, agora: () => AGORA, urlAviso: "https://x/aviso-mp", novoId: () => "11111111-1111-4111-8111-111111111111",
    mp: { async criarPagamento(corpo, chave) {
      estado.chamadasMp.push({ corpo, chave });
      return over.mpOk === false
        ? { ok: false, status: over.mpStatus ?? 500, json: { message: "falhou" } }
        : { ok: true, status: 201, json: { id: 998877, point_of_interaction: { transaction_data: { qr_code: "00020126...", qr_code_base64: "iVBOR...", ticket_url: "https://mp/ticket" } } } };
    } },
  };
  return { estado, deps };
}

test("cria o Pix com o valor do servidor e reserva o horário por 30 minutos", async () => {
  const { estado, deps } = montar();
  const r = await criarPix({ appointment_id: 7, cpf: CPF }, deps);
  assert.equal(r.status, 200);
  assert.equal(r.body.amount, 45); assert.equal(r.body.qr_code, "00020126..."); assert.equal(r.body.status, "pendente");
  assert.equal(r.body.expires_at, "2026-10-20T15:30:00.000Z");
  const { corpo, chave } = estado.chamadasMp[0];
  assert.equal(corpo.payment_method_id, "pix"); assert.equal(corpo.transaction_amount, 45); assert.equal(corpo.date_of_expiration, "2026-10-20T12:30:00.000-03:00");
  assert.equal(corpo.external_reference, "11111111-1111-4111-8111-111111111111"); assert.equal(chave, "pix-11111111-1111-4111-8111-111111111111");
  assert.equal(corpo.notification_url, "https://x/aviso-mp"); assert.equal(corpo.payer.email, "maria@x.com");
  const linha = estado.pagamentos.get("11111111-1111-4111-8111-111111111111");
  assert.equal(linha.provider_payment_id, "998877"); assert.equal(linha.payer_cpf_last3, "725");
  assert.ok(!JSON.stringify(linha).includes("52998224725"), "nunca guarda o CPF completo");
  assert.deepEqual(estado.agendamento, { payment_status: "pendente", reserved_until: "2026-10-20T15:30:00.000Z" });
  assert.equal(estado.expirou, 1, "vence o que estava pendente antes de decidir");
});

test("valor alterado no navegador é ignorado: nenhum campo de valor da entrada é lido", async () => {
  const { estado, deps } = montar();
  const r = await criarPix({ appointment_id: 7, cpf: CPF, amount: 1, valor: 1, transaction_amount: 1 } as any, deps);
  assert.equal(r.status, 200); assert.equal(estado.chamadasMp[0].corpo.transaction_amount, 45);
});

test("cupom do banco entra na conta; serviço fora do catálogo é recusado", async () => {
  const a = montar({ ag: { services: ["Corte Degradê", "Barba Express"], coupon_code: "dez" } });
  assert.equal((await criarPix({ appointment_id: 7, cpf: CPF }, a.deps)).body.amount, 63);
  const b = montar({ ag: { services: ["Corte Fantasma"] } });
  const r = await criarPix({ appointment_id: 7, cpf: CPF }, b.deps);
  assert.equal(r.status, 422); assert.equal(b.estado.chamadasMp.length, 0);
});

test("atualizar a página devolve o mesmo QR, sem cobrança nova", async () => {
  const aberto: Pagamento = { id: "existente", status: "pendente", amount: 45, expires_at: "2026-10-20T15:20:00.000Z", pix_qr_code: "QR-VELHO", pix_qr_base64: null, ticket_url: null };
  const { estado, deps } = montar({ pendente: aberto });
  const r = await criarPix({ appointment_id: 7, cpf: CPF }, deps);
  assert.equal(r.status, 200); assert.equal(r.body.qr_code, "QR-VELHO"); assert.equal(estado.chamadasMp.length, 0);
});

test("recusas: CPF inválido, agendamento inexistente, cancelado ou já pago", async () => {
  assert.equal((await criarPix({ appointment_id: 7, cpf: "111.111.111-11" }, montar().deps)).body.erro, "cpf_invalido");
  assert.equal((await criarPix({ appointment_id: "abc", cpf: CPF }, montar().deps)).status, 400);
  assert.equal((await criarPix({ appointment_id: 7, cpf: CPF }, montar({ ag: null }).deps)).status, 404);
  assert.equal((await criarPix({ appointment_id: 7, cpf: CPF }, montar({ ag: { status: "cancelado" } }).deps)).status, 409);
  const pago = montar({ ag: { payment_status: "pago" } });
  assert.equal((await criarPix({ appointment_id: 7, cpf: CPF }, pago.deps)).body.erro, "ja_pago"); assert.equal(pago.estado.chamadasMp.length, 0);
});

test("Mercado Pago fora do ar: cobrança cancelada, nada reservado, erro claro pro site", async () => {
  const { estado, deps } = montar({ mpOk: false, mpStatus: 503 });
  const r = await criarPix({ appointment_id: 7, cpf: CPF }, deps);
  assert.equal(r.status, 502); assert.equal(r.body.erro, "mercado_pago_indisponivel");
  assert.equal(estado.pagamentos.get("11111111-1111-4111-8111-111111111111").status, "cancelado");
  assert.deepEqual(estado.agendamento, { payment_status: "nenhum" });
});
