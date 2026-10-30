// Aviso (webhook) do InfinitePay + conferência na volta do cliente. O aviso NÃO tem assinatura, então nada nele vale por si só:
// a cobrança tem que ser nossa (order_nsu = id da cobrança) e o InfinitePay tem que confirmar o pagamento agora (payment_check),
// com valor pago >= o valor que NÓS cobramos (lido do banco, nunca do corpo recebido).

export interface Repo {
  cobranca(id: string): Promise<{ id: string; status: string; appointment_id: number; amount: number } | null>;
  registrarAprovado(id: string, providerId: string, fee: number | null, net: number | null, pagoEm: string): Promise<string>;
}
export interface InfinitePay { consultar(q: { order_nsu: string; transaction_nsu: string; slug: string }): Promise<{ ok: boolean; status: number; json: any }>; }
export type Deps = { repo: Repo; infinitepay: InfinitePay; agora?: () => Date; log?: (m: string) => void };
export type Resposta = { status: number; body: Record<string, unknown> };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const texto = (v: unknown) => (typeof v === "string" ? v.trim() : "");

/** Serve o webhook ({ order_nsu, transaction_nsu, invoice_slug, ... }) e a conferência do site ({ order_nsu, transaction_nsu, slug }): mesmo caminho. */
export async function tratarAvisoInfinitePay(corpo: string, deps: Deps): Promise<Resposta> {
  let a: any;
  try { a = JSON.parse(corpo); } catch { return { status: 400, body: { erro: "corpo_invalido" } }; }
  const orderNsu = texto(a?.order_nsu), transactionNsu = texto(a?.transaction_nsu), slug = texto(a?.invoice_slug ?? a?.slug);
  if (!UUID.test(orderNsu)) return { status: 200, body: { ignorado: true } };           // não é cobrança nossa
  if (!transactionNsu || !slug) return { status: 400, body: { erro: "faltam_transaction_nsu_ou_slug" } };

  const linha = await deps.repo.cobranca(orderNsu);
  if (!linha) { deps.log?.(`aviso-infinitepay: order_nsu ${orderNsu} sem cobrança nossa`); return { status: 200, body: { ignorado: true } }; }
  if (linha.status === "aprovado") return { status: 200, body: { resultado: "ja_aprovado" } };

  const r = await deps.infinitepay.consultar({ order_nsu: orderNsu, transaction_nsu: transactionNsu, slug });
  // 400 faz o InfinitePay reenviar o aviso
  if (!r.ok) { deps.log?.(`aviso-infinitepay: payment_check falhou (HTTP ${r.status}) para ${orderNsu}`); return { status: 400, body: { erro: "consulta_falhou" } }; }
  if (r.json?.paid !== true) return { status: 200, body: { resultado: "pendente" } };

  const pagoCentavos = Number(r.json?.paid_amount ?? 0), devidoCentavos = Math.round(linha.amount * 100);
  if (!(pagoCentavos >= devidoCentavos)) {
    deps.log?.(`aviso-infinitepay: ATENÇÃO ${orderNsu} pago ${pagoCentavos} < devido ${devidoCentavos}: não dei baixa`);
    return { status: 200, body: { resultado: "valor_incompleto" } };
  }
  // o InfinitePay não devolve a taxa nesta consulta: fica em branco e o Financeiro usa a taxa cadastrada
  const resultado = await deps.repo.registrarAprovado(linha.id, transactionNsu, null, null, (deps.agora?.() ?? new Date()).toISOString());
  if (resultado === "precisa_estorno") deps.log?.(`aviso-infinitepay: ATENÇÃO ${orderNsu} pago depois de vencer e o horário já foi ocupado: devolver à mão`);
  return { status: 200, body: { resultado } };
}
