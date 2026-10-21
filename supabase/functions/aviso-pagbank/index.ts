// Edge Function aviso-pagbank: webhook de pedidos do PagBank (cadastrado no pedido, em notification_urls, pela criar-pix).
// Deploy sem verificação de JWT (o PagBank não manda JWT).
// Segredos: PAGBANK_TOKEN (o mesmo token da conta, usado também na assinatura do aviso) e PAGBANK_SANDBOX ("true" enquanto estiver testando).
import { createClient } from "npm:@supabase/supabase-js@2";
import { tratarAvisoPagBank, type Repo } from "./handler.ts";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const repo: Repo = {
  async pagamentoPorReferencia(ref, providerId) {
    const q = UUID.test(ref) ? db.from("appointment_payments").select("id,status,appointment_id").eq("id", ref) : db.from("appointment_payments").select("id,status,appointment_id").eq("provider_payment_id", providerId);
    const { data, error } = await q.maybeSingle();
    if (error) throw new Error(error.message);
    return data as any;
  },
  async registrarAprovado(id, providerId, fee, net, pagoEm) {
    const { data, error } = await db.rpc("registrar_pagamento_aprovado", { p_payment_id: id, p_provider_id: providerId, p_fee: fee, p_net: net, p_paid_at: pagoEm });
    if (error) throw new Error(error.message);
    return String(data);
  },
  async marcarEstornado(id, appointmentId) {
    await db.from("appointment_payments").update({ status: "estornado", refunded_at: new Date().toISOString(), needs_refund: false }).eq("id", id);
    await db.from("appointments").update({ payment_status: "estornado" }).eq("id", appointmentId);
  },
};

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("método não permitido", { status: 405 });
  try {
    const corpo = await req.text();   // corpo BRUTO: qualquer reformatação muda o hash da autenticidade
    const token = Deno.env.get("PAGBANK_TOKEN") ?? "";
    const base = (Deno.env.get("PAGBANK_SANDBOX") ?? "true") !== "false" ? "https://sandbox.api.pagseguro.com" : "https://api.pagseguro.com";
    const r = await tratarAvisoPagBank(
      { corpo, xAuthenticityToken: req.headers.get("x-authenticity-token") },
      {
        token, repo, log: (m) => console.error(m),
        pagbank: {
          async consultarPedido(id) {
            const resp = await fetch(`${base}/orders/${encodeURIComponent(id)}`, { headers: { Authorization: `Bearer ${token}`, Accept: "application/json" } });
            return { ok: resp.ok, status: resp.status, json: await resp.json().catch(() => ({})) };
          },
        },
      },
    );
    return new Response(JSON.stringify(r.body), { status: r.status, headers: { "Content-Type": "application/json" } });
  } catch (e) {
    console.error("aviso-pagbank:", e instanceof Error ? e.message : e);
    return new Response(JSON.stringify({ erro: "erro_interno" }), { status: 500 });   // o PagBank reenvia
  }
});
