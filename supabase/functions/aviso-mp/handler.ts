// Recebe o aviso (webhook) do Mercado Pago, confere a assinatura e CONSULTA o pagamento na API antes de marcar como pago.
import { assinaturaValida, estadoDoMercadoPago, taxaELiquido } from "../_shared/pix-core.ts";

export interface Repo {
  pagamentoPorReferencia(ref: string, providerId: string): Promise<{ id: string; status: string; appointment_id: number } | null>;
  registrarAprovado(id: string, providerId: string, fee: number, net: number, pagoEm: string): Promise<string>;
  marcarEstornado(id: string, appointmentId: number): Promise<void>;
}
export interface Mp { buscarPagamento(id: string): Promise<{ ok: boolean; status: number; json: any }>; }
export type Deps = { secret: string; repo: Repo; mp: Mp; log?: (m: string) => void };
export type Resposta = { status: number; body: Record<string, unknown> };

export async function tratarAviso(a: { dataId: string | null; tipo: string | null; xSignature: string | null; xRequestId: string | null }, deps: Deps): Promise<Resposta> {
  if (!(await assinaturaValida({ secret: deps.secret, xSignature: a.xSignature, xRequestId: a.xRequestId, dataId: a.dataId }))) {
    deps.log?.("aviso-mp: assinatura inválida");
    return { status: 401, body: { erro: "assinatura_invalida" } };
  }
  if (a.tipo !== "payment" || !a.dataId) return { status: 200, body: { ignorado: true } };   // outros tópicos: só confirma o recebimento

  const r = await deps.mp.buscarPagamento(a.dataId);
  if (!r.ok) { deps.log?.(`aviso-mp: não consegui consultar o pagamento ${a.dataId} (HTTP ${r.status})`); return { status: 502, body: { erro: "consulta_falhou" } }; }   // 5xx: o Mercado Pago reenvia
  const pg = r.json;
  const linha = await deps.repo.pagamentoPorReferencia(String(pg.external_reference ?? ""), String(pg.id ?? a.dataId));
  if (!linha) { deps.log?.(`aviso-mp: pagamento ${a.dataId} sem cobrança nossa (external_reference ${pg.external_reference})`); return { status: 200, body: { ignorado: true } }; }

  const estado = estadoDoMercadoPago(pg.status);
  if (estado === "aprovado") {
    const { fee, net } = taxaELiquido(pg);
    const resultado = await deps.repo.registrarAprovado(linha.id, String(pg.id), fee, net, String(pg.date_approved ?? new Date().toISOString()));
    if (resultado === "precisa_estorno") deps.log?.(`aviso-mp: ATENÇÃO pagamento ${a.dataId} pago depois de vencer e o horário já foi ocupado: estornar à mão`);
    return { status: 200, body: { resultado } };
  }
  if (estado === "estornado" && linha.status !== "estornado") { await deps.repo.marcarEstornado(linha.id, linha.appointment_id); return { status: 200, body: { resultado: "estornado" } }; }
  return { status: 200, body: { resultado: estado } };   // pendente/vencido: quem vence é a rotina de expiração
}
