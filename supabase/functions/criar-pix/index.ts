// Edge Function criar-pix: o site chama com { appointment_id, cpf, email? } e recebe o QR Code do Pix.
// Deploy:   supabase functions deploy criar-pix           (com verificação de JWT: o site manda a chave pública do Supabase)
// Segredos: supabase secrets set MP_ACCESS_TOKEN=...      (SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY já existem no ambiente)
import { createClient } from "npm:@supabase/supabase-js@2";
import { criarPix, type Repo } from "./handler.ts";

const ORIGENS = ["https://primebarbearia.app.br", "https://www.primebarbearia.app.br", "https://staff.primebarbearia.app.br"];
const cors = (req: Request) => ({
  "Access-Control-Allow-Origin": ORIGENS.includes(req.headers.get("origin") ?? "") ? req.headers.get("origin")! : ORIGENS[0],
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin",
});

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const must = <T>(r: { data: T; error: { message: string } | null }): T => { if (r.error) throw new Error(r.error.message); return r.data; };

const repo: Repo = {
  async expirar() { await db.rpc("expirar_pagamentos_pix"); },
  async agendamento(id) { return must(await db.from("appointments").select("id,status,payment_status,services,coupon_code,client_name,client_email,day").eq("id", id).maybeSingle()) as any; },
  async catalogo() { return Object.fromEntries((must(await db.from("services").select("name,price").eq("active", true)) as any[]).map((s) => [s.name, Number(s.price)])); },
  async cupom(code) { return must(await db.from("coupons").select("code,type,value,services,active").eq("code", code).eq("active", true).maybeSingle()) as any; },
  async pagamentoPendente(appointmentId) { return must(await db.from("appointment_payments").select("id,status,amount,expires_at,pix_qr_code,pix_qr_base64,ticket_url").eq("appointment_id", appointmentId).eq("status", "pendente").maybeSingle()) as any; },
  async inserirPagamento(p) { must(await db.from("appointment_payments").insert(p)); },
  async atualizarPagamento(id, patch) { must(await db.from("appointment_payments").update(patch).eq("id", id)); },
  async marcarAgendamento(id, patch) { must(await db.from("appointments").update(patch).eq("id", id)); },
};

Deno.serve(async (req) => {
  const headers = { ...cors(req), "Content-Type": "application/json" };
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers });
  if (req.method !== "POST") return new Response(JSON.stringify({ erro: "método não permitido" }), { status: 405, headers });
  try {
    const entrada = await req.json().catch(() => ({}));
    const r = await criarPix(entrada, {
      repo,
      agora: () => new Date(),
      novoId: () => crypto.randomUUID(),
      urlAviso: `${Deno.env.get("SUPABASE_URL")}/functions/v1/aviso-mp`,
      log: (m) => console.error(m),
      mp: {
        async criarPagamento(corpo, chave) {
          const resp = await fetch("https://api.mercadopago.com/v1/payments", {
            method: "POST",
            headers: { "Content-Type": "application/json", Authorization: `Bearer ${Deno.env.get("MP_ACCESS_TOKEN")}`, "X-Idempotency-Key": chave },
            body: JSON.stringify(corpo),
          });
          return { ok: resp.ok, status: resp.status, json: await resp.json().catch(() => ({})) };
        },
      },
    });
    return new Response(JSON.stringify(r.body), { status: r.status, headers });
  } catch (e) {
    console.error("criar-pix:", e instanceof Error ? e.message : e);
    return new Response(JSON.stringify({ erro: "erro_interno" }), { status: 500, headers });
  }
});
