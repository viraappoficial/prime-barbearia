// Aviso (webhook) do PagBank: confere a autenticidade (x-authenticity-token) e CONSULTA o pedido na API antes de marcar como pago.
import { autenticidadePagBankValida, estadoDoPagBank } from "../_shared/pix-core.ts";

export interface Repo {
  pagamentoPorReferencia(ref: string, providerId: string): Promise<{ id: string; status: string; appointment_id: number } | null>;
  registrarAprovado(id: string, providerId: string, fee: number | null, net: number | null, pagoEm: string): Promise<string>;
  marcarEstornado(id: string, appointmentId: number): Promise<void>;
}
export interface PagBank { consultarPedido(id: string): Promise<{ ok: boolean; status: number; json: any }>; }
export type Deps = { token: string; repo: Repo; pagbank: PagBank; log?: (m: string) => void };
export type Resposta = { status: number; body: Record<string, unknown> };

export async function tratarAvisoPagBank(a: { corpo: string; xAuthenticityToken: string | null }, deps: Deps): Promise<Resposta> {
  if (!(await autenticidadePagBankValida({ token: deps.token, corpo: a.corpo, xAuthenticityToken: a.xAuthenticityToken }))) {
    deps.log?.("aviso-pagbank: autenticidade inválida");
    return { status: 401, body: { erro: "autenticidade_invalida" } };
  }
  let aviso: any;
  try { aviso = JSON.parse(a.corpo); } catch { return { status: 400, body: { erro: "corpo_invalido" } }; }
  const orderId = typeof aviso?.id === "string" ? aviso.id : null;
  if (!orderId || !String(orderId).startsWith("ORDE_")) return { status: 200, body: { ignorado: true } };   // outros formatos (pós-transacionais): só confirma o recebimento

  const r = await deps.pagbank.consultarPedido(orderId);   // o que vale é o que o PagBank diz agora, não o corpo recebido
  if (!r.ok) { deps.log?.(`aviso-pagbank: não consegui consultar o pedido ${orderId} (HTTP ${r.status})`); return { status: 502, body: { erro: "consulta_falhou" } }; }
  const pedido = r.json;
  const cobranca = pedido?.charges?.[0];
  const linha = await deps.repo.pagamentoPorReferencia(String(pedido?.reference_id ?? ""), orderId);
  if (!linha) { deps.log?.(`aviso-pagbank: pedido ${orderId} sem cobrança nossa (reference_id ${pedido?.reference_id})`); return { status: 200, body: { ignorado: true } }; }

  const estado = estadoDoPagBank(cobranca?.status);
  // devolução: no PagBank o pedido devolvido continua PAID, só o valor devolvido muda; confere antes da aprovação
  const devolvido = Number(cobranca?.amount?.summary?.refunded ?? 0) > 0;
  if (devolvido && linha.status === "aprovado") { await deps.repo.marcarEstornado(linha.id, linha.appointment_id); return { status: 200, body: { resultado: "estornado" } }; }
  if (estado === "aprovado") {
    // o PagBank não devolve a tarifa no pedido: a taxa fica em branco aqui e o Financeiro usa a tarifa cadastrada
    const resultado = await deps.repo.registrarAprovado(linha.id, orderId, null, null, String(cobranca?.paid_at ?? new Date().toISOString()));
    if (resultado === "precisa_estorno") deps.log?.(`aviso-pagbank: ATENÇÃO pedido ${orderId} pago depois de vencer e o horário já foi ocupado: estornar à mão`);
    return { status: 200, body: { resultado } };
  }
  return { status: 200, body: { resultado: estado } };   // pendente/vencido: quem vence é a rotina de expiração
}
