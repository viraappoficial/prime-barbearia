// Provedores de Pix trocáveis: o resto do sistema (valor, reserva, aviso, Financeiro) não sabe qual está por baixo.
import { montarPagamentoPix, montarPedidoPixPagBank, extrairPixPagBank, type EntradaPix } from "./pix-core.ts";

export type ResultadoPix = { ok: boolean; status: number; id?: string; qr_code?: string; qr_base64?: string | null; ticket_url?: string | null; erro?: string };
export interface Provedor { criarPix(e: EntradaPix, chaveIdempotencia: string): Promise<ResultadoPix>; }
type Fetch = (url: string, init: { method: string; headers: Record<string, string>; body?: string }) => Promise<{ ok: boolean; status: number; json(): Promise<any> }>;

export function provedorMercadoPago(cfg: { token: string; fetch?: Fetch }): Provedor {
  const f = cfg.fetch ?? (fetch as unknown as Fetch);
  return {
    async criarPix(e, chave) {
      const r = await f("https://api.mercadopago.com/v1/payments", {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${cfg.token}`, "X-Idempotency-Key": chave },
        body: JSON.stringify(montarPagamentoPix(e)),
      });
      const json = await r.json().catch(() => ({}));
      const td = json?.point_of_interaction?.transaction_data;
      if (!r.ok || !td?.qr_code) return { ok: false, status: r.status, erro: JSON.stringify(json?.message ?? json?.cause ?? "").slice(0, 300) };
      return { ok: true, status: r.status, id: String(json.id), qr_code: td.qr_code, qr_base64: td.qr_code_base64 ?? null, ticket_url: td.ticket_url ?? null };
    },
  };
}

export function provedorPagBank(cfg: { token: string; sandbox: boolean; fetch?: Fetch }): Provedor {
  const f = cfg.fetch ?? (fetch as unknown as Fetch);
  const base = cfg.sandbox ? "https://sandbox.api.pagseguro.com" : "https://api.pagseguro.com";
  return {
    async criarPix(e, chave) {
      const r = await f(`${base}/orders`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json", Authorization: `Bearer ${cfg.token}`, "x-idempotency-key": chave },
        body: JSON.stringify(montarPedidoPixPagBank(e)),
      });
      const json = await r.json().catch(() => ({}));
      const pix = extrairPixPagBank(json);
      if (!r.ok || !pix) return { ok: false, status: r.status, erro: JSON.stringify(json?.error_messages ?? json?.message ?? "").slice(0, 300) };
      return { ok: true, status: r.status, id: pix.id, qr_code: pix.qr_code, qr_base64: null, ticket_url: pix.imagem };
    },
  };
}
