// Edge Function aviso-infinitepay: webhook do InfinitePay (url definida em cada link, pela criar-pix) e conferência na volta do cliente.
// Deploy SEM verificação de JWT (o InfinitePay não manda JWT):  supabase functions deploy aviso-infinitepay --no-verify-jwt
// Variáveis: INFINITEPAY_HANDLE (a InfiniteTag, sem o $) e, só se a conta exigir, o segredo INFINITEPAY_TOKEN.
import { createClient } from "npm:@supabase/supabase-js@2";
import { tratarAvisoInfinitePay, type Repo } from "./handler.ts";
import { consultarPagamentoInfinitePay } from "../_shared/provedores.ts";

const ORIGENS = ["https://primebarbearia.app.br", "https://www.primebarbearia.app.br", "https://staff.primebarbearia.app.br"];
const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

const repo: Repo = {
  async cobranca(id) {
    const { data, error } = await db.from("appointment_payments").select("id,status,appointment_id,amount").eq("id", id).maybeSingle();
    if (error) throw new Error(error.message);
    return data ? { ...(data as any), amount: Number((data as any).amount) } : null;
  },
  async registrarAprovado(id, providerId, fee, net, pagoEm) {
    const { data, error } = await db.rpc("registrar_pagamento_aprovado", { p_payment_id: id, p_provider_id: providerId, p_fee: fee, p_net: net, p_paid_at: pagoEm });
    if (error) throw new Error(error.message);
    return String(data);
  },
};

Deno.serve(async (req) => {
  const origem = req.headers.get("origin") ?? "";
  const cors = { "Access-Control-Allow-Origin": ORIGENS.includes(origem) ? origem : ORIGENS[0], "Access-Control-Allow-Headers": "content-type, authorization, apikey, x-client-info", "Access-Control-Allow-Methods": "POST, OPTIONS", "Vary": "Origin" };
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return new Response("método não permitido", { status: 405, headers: cors });
  try {
    const cfg = { handle: Deno.env.get("INFINITEPAY_HANDLE") ?? "", token: Deno.env.get("INFINITEPAY_TOKEN") || undefined };
    const r = await tratarAvisoInfinitePay(await req.text(), { repo, log: (m) => console.error(m), infinitepay: { consultar: (q) => consultarPagamentoInfinitePay(cfg, q) } });
    return new Response(JSON.stringify(r.body), { status: r.status, headers: { ...cors, "Content-Type": "application/json" } });
  } catch (e) {
    console.error("aviso-infinitepay:", e instanceof Error ? e.message : e);
    return new Response(JSON.stringify({ erro: "erro_interno" }), { status: 500, headers: cors });   // o InfinitePay reenvia
  }
});
