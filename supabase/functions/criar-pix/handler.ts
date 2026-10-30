// Cria (ou devolve) a cobrança Pix de um agendamento. Lógica pura: o banco e o Mercado Pago entram por `deps`.
import { calcularValor, cpfValido, dataExpiracao, type Cupom } from "../_shared/pix-core.ts";
import type { Provedor } from "../_shared/provedores.ts";

export type Agendamento = { id: number; status: string; payment_status: string; services: string[]; coupon_code: string | null; client_name: string | null; client_email: string | null; day: string };
export type Pagamento = { id: string; status: string; amount: number; expires_at: string; pix_qr_code: string | null; pix_qr_base64: string | null; ticket_url: string | null };

export interface Repo {
  expirar(): Promise<void>;
  agendamento(id: number): Promise<Agendamento | null>;
  catalogo(): Promise<Record<string, number>>;
  cupom(code: string): Promise<Cupom | null>;
  pagamentoPendente(appointmentId: number): Promise<Pagamento | null>;
  inserirPagamento(p: { id: string; appointment_id: number; amount: number; expires_at: string; payer_cpf_last3: string }): Promise<void>;
  atualizarPagamento(id: string, patch: Record<string, unknown>): Promise<void>;
  marcarAgendamento(id: number, patch: { payment_status: string; reserved_until: string | null }): Promise<void>;
}
export type Deps = { repo: Repo; provedor: Provedor; agora: () => Date; urlAviso: string; novoId: () => string; log?: (m: string) => void; exigeCpf?: boolean };   // exigeCpf: Mercado Pago/PagBank pedem; o checkout do InfinitePay coleta os dados do pagador sozinho
export type Resposta = { status: number; body: Record<string, unknown> };

const resposta = (p: Pagamento) => ({ payment_id: p.id, status: p.status, amount: p.amount, expires_at: p.expires_at, qr_code: p.pix_qr_code, qr_base64: p.pix_qr_base64, ticket_url: p.ticket_url });

export async function criarPix(entrada: { appointment_id?: unknown; cpf?: unknown; email?: unknown }, deps: Deps): Promise<Resposta> {
  const { repo, provedor, agora } = deps;
  const appId = Number(entrada.appointment_id);
  if (!Number.isInteger(appId) || appId <= 0) return { status: 400, body: { erro: "agendamento inválido" } };
  const exigeCpf = deps.exigeCpf !== false;
  if (exigeCpf && !cpfValido(String(entrada.cpf ?? ""))) return { status: 400, body: { erro: "cpf_invalido" } };

  await repo.expirar();   // vence o que está pendente há mais de 30 min antes de decidir qualquer coisa
  const ag = await repo.agendamento(appId);
  if (!ag) return { status: 404, body: { erro: "agendamento não encontrado" } };
  if (!["pendente", "confirmado"].includes(ag.status)) return { status: 409, body: { erro: "agendamento_nao_aceita_pagamento" } };
  if (ag.payment_status === "pago") return { status: 409, body: { erro: "ja_pago" } };

  // já tem um Pix em aberto: devolve o mesmo QR (atualizar a página não gera cobrança nova)
  const aberto = await repo.pagamentoPendente(appId);
  if (aberto && Date.parse(aberto.expires_at) > agora().getTime()) return { status: 200, body: resposta(aberto) };

  // valor SEMPRE recalculado aqui, a partir do catálogo e do cupom do banco; nada vem do navegador
  const cupom = ag.coupon_code ? await repo.cupom(ag.coupon_code.toUpperCase()) : null;
  const calc = calcularValor(ag.services ?? [], await repo.catalogo(), cupom);
  if ("erro" in calc) return { status: 422, body: { erro: calc.erro } };
  if (calc.total < 0.01) return { status: 422, body: { erro: "valor_zero" } };

  const id = deps.novoId();
  const expira = dataExpiracao(agora(), 30);
  const cpf = String(entrada.cpf ?? "").replace(/\D/g, "");
  await repo.inserirPagamento({ id, appointment_id: appId, amount: calc.total, expires_at: new Date(Date.parse(expira)).toISOString(), payer_cpf_last3: cpf.slice(-3) });

  const email = String(entrada.email ?? "").trim() || ag.client_email || `pix+${appId}@primebarbearia.app.br`;
  const r = await provedor.criarPix(
    { valor: calc.total, descricao: `Prime Barbearia - ${(ag.services ?? []).join(" + ")}`, email, nome: ag.client_name ?? "Cliente", cpf, referencia: id, urlAviso: deps.urlAviso, expira },
    `pix-${id}`,   // a mesma chave numa repetição nunca cobra duas vezes
  );
  if (!r.ok || (!r.qr_code && !r.ticket_url)) {   // Mercado Pago/PagBank devolvem QR Code; InfinitePay devolve só o link do checkout
    deps.log?.(`criar-pix: o provedor recusou (HTTP ${r.status}): ${r.erro ?? ""}`);
    await repo.atualizarPagamento(id, { status: "cancelado" });
    return { status: 502, body: { erro: "provedor_indisponivel" } };
  }
  const pagamento: Pagamento = { id, status: "pendente", amount: calc.total, expires_at: new Date(Date.parse(expira)).toISOString(), pix_qr_code: r.qr_code ?? null, pix_qr_base64: r.qr_base64 ?? null, ticket_url: r.ticket_url ?? null };
  await repo.atualizarPagamento(id, { provider_payment_id: String(r.id), pix_qr_code: pagamento.pix_qr_code, pix_qr_base64: pagamento.pix_qr_base64, ticket_url: pagamento.ticket_url });
  await repo.marcarAgendamento(appId, { payment_status: "pendente", reserved_until: pagamento.expires_at });
  return { status: 200, body: resposta(pagamento) };
}
