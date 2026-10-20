// Regras puras do Pix (sem Deno nem rede): valor, CPF, vencimento, assinatura do aviso, taxa e estado.
// Usado por criar-pix e aviso-mp, e testado com o Node (pix-core.test.ts).

export type Cupom = { code: string; type: string; value: number; services: string[] | null; active?: boolean };

/** Mesma conta do site (primeApplyCoupon): cupom de valor fixo vira o total; percentual desconta do total; cupom restrito vale pra um serviço só. */
export function calcularValor(nomes: string[], catalogo: Record<string, number>, cupom: Cupom | null): { total: number; bruto: number; cupomAplicado: boolean } | { erro: string } {
  if (!nomes.length) return { erro: "agendamento sem serviço" };
  let bruto = 0;
  for (const n of nomes) {
    const preco = catalogo[n];
    if (typeof preco !== "number" || !(preco >= 0)) return { erro: `serviço fora do catálogo: ${n}` };
    bruto += preco;
  }
  bruto = Math.round(bruto * 100) / 100;
  let total = bruto, cupomAplicado = false;
  if (cupom && cupom.active !== false) {
    const restrito = cupom.services && cupom.services.length > 0;
    const vale = !restrito || (nomes.length === 1 && cupom.services!.includes(nomes[0]));
    if (vale && cupom.type === "valor_fixo" && cupom.value >= 0) { total = cupom.value; cupomAplicado = true; }
    else if (vale && cupom.type === "percentual" && cupom.value > 0 && cupom.value < 100) { total = Math.round(bruto * (1 - cupom.value / 100) * 100) / 100; cupomAplicado = true; }
  }
  if (total > bruto) total = bruto;   // cupom nunca aumenta o valor
  return { total: Math.round(total * 100) / 100, bruto, cupomAplicado };
}

export function cpfValido(cpf: string): boolean {
  const d = String(cpf ?? "").replace(/\D/g, "");
  if (d.length !== 11 || /^(\d)\1{10}$/.test(d)) return false;
  const dig = (base: string, peso: number) => { let s = 0; for (const c of base) s += Number(c) * peso--; const r = (s * 10) % 11; return r === 10 ? 0 : r; };
  return dig(d.slice(0, 9), 10) === Number(d[9]) && dig(d.slice(0, 10), 11) === Number(d[10]);
}

/** ISO 8601 com fuso -03:00 (São Paulo não tem horário de verão desde 2019). O Mercado Pago aceita de 30 minutos a 30 dias. */
export function dataExpiracao(agora: Date, minutos = 30): string {
  const t = new Date(agora.getTime() + Math.max(30, minutos) * 60_000);
  const sp = new Date(t.getTime() - 3 * 3_600_000);
  return sp.toISOString().replace("Z", "").replace(/\.\d{3}$/, ".000") + "-03:00";
}

export type EntradaPix = { valor: number; descricao: string; email: string; nome: string; cpf: string; referencia: string; urlAviso: string; expira: string };

/** Corpo do POST /v1/payments para Pix. */
export function montarPagamentoPix(e: EntradaPix) {
  return {
    transaction_amount: e.valor,
    description: e.descricao.slice(0, 250),
    payment_method_id: "pix",
    external_reference: e.referencia,
    notification_url: e.urlAviso,
    date_of_expiration: e.expira,
    payer: { email: e.email, first_name: e.nome.trim().split(/\s+/)[0] || "Cliente", identification: { type: "CPF", number: e.cpf.replace(/\D/g, "") } },
  };
}

const enc = new TextEncoder();
const hex = (b: ArrayBuffer) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");
const iguais = (a: string, b: string) => { if (a.length !== b.length) return false; let d = 0; for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i); return d === 0; };

/** Confere o x-signature ("ts=...,v1=...") do aviso: HMAC-SHA256 do manifesto `id:<data.id>;request-id:<x-request-id>;ts:<ts>;` com a assinatura secreta.
 * (Formato do Mercado Pago; confirmar com uma notificação real na conta de teste.) */
export async function assinaturaValida(p: { secret: string; xSignature: string | null; xRequestId: string | null; dataId: string | null }): Promise<boolean> {
  if (!p.secret || !p.xSignature || !p.dataId) return false;
  const partes = Object.fromEntries(p.xSignature.split(",").map((kv) => { const i = kv.indexOf("="); return [kv.slice(0, i).trim(), kv.slice(i + 1).trim()]; }));
  const ts = partes["ts"], v1 = partes["v1"];
  if (!ts || !v1) return false;
  const id = /^[a-z0-9]+$/i.test(p.dataId) ? p.dataId.toLowerCase() : p.dataId;
  const manifesto = `id:${id};request-id:${p.xRequestId ?? ""};ts:${ts};`;
  const key = await crypto.subtle.importKey("raw", enc.encode(p.secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return iguais(hex(await crypto.subtle.sign("HMAC", key, enc.encode(manifesto))), v1.toLowerCase());
}

export type EstadoPagamento = "aprovado" | "pendente" | "vencido" | "estornado";
export function estadoDoMercadoPago(status: string | undefined): EstadoPagamento {
  switch (status) {
    case "approved": case "authorized": return "aprovado";
    case "refunded": case "charged_back": return "estornado";
    case "cancelled": case "rejected": case "expired": return "vencido";
    default: return "pendente";
  }
}

/** Taxa e líquido de um pagamento do Mercado Pago. */
export function taxaELiquido(pg: any): { fee: number; net: number } {
  const amount = Number(pg?.transaction_amount ?? 0);
  const fee = Math.round(((pg?.fee_details ?? []) as any[]).reduce((s, f) => s + Number(f?.amount ?? 0), 0) * 100) / 100;
  const net = pg?.transaction_details?.net_received_amount != null ? Number(pg.transaction_details.net_received_amount) : Math.round((amount - fee) * 100) / 100;
  return { fee, net };
}
