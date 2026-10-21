// Edge Function aviso-mp: webhook de pagamentos do Mercado Pago. Confere a assinatura, consulta o pagamento e marca como pago.
// Deploy sem verificação de JWT (o Mercado Pago não manda JWT):  supabase functions deploy aviso-mp --no-verify-jwt
// Segredos: MP_ACCESS_TOKEN e MP_WEBHOOK_SECRET (a assinatura secreta gerada em Webhooks > Configurar notificações).
// URL a cadastrar no painel do Mercado Pago:  https://<projeto>.supabase.co/functions/v1/aviso-mp
import { createClient } from "npm:@supabase/supabase-js@2";
import { tratarAviso, type Repo } from "./handler.ts";

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
    const url = new URL(req.url);
    const corpo = await req.json().catch(() => ({} as any));
    const dataId = url.searchParams.get("data.id") ?? (corpo?.data?.id != null ? String(corpo.data.id) : null);
    const tipo = url.searchParams.get("type") ?? url.searchParams.get("topic") ?? corpo?.type ?? null;
    const r = await tratarAviso(
      { dataId, tipo, xSignature: req.headers.get("x-signature"), xRequestId: req.headers.get("x-request-id") },
      {
        secret: Deno.env.get("MP_WEBHOOK_SECRET") ?? "",
        repo,
        log: (m) => console.error(m),
        mp: {
          async buscarPagamento(id) {
            const resp = await fetch(`https://api.mercadopago.com/v1/payments/${encodeURIComponent(id)}`, { headers: { Authorization: `Bearer ${Deno.env.get("MP_ACCESS_TOKEN")}` } });
            return { ok: resp.ok, status: resp.status, json: await resp.json().catch(() => ({})) };
          },
        },
      },
    );
    return new Response(JSON.stringify(r.body), { status: r.status, headers: { "Content-Type": "application/json" } });
  } catch (e) {
    console.error("aviso-mp:", e instanceof Error ? e.message : e);
    return new Response(JSON.stringify({ erro: "erro_interno" }), { status: 500 });   // o Mercado Pago reenvia
  }
});
