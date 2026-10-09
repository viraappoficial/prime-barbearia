// Webhook da WhatsApp Cloud API (Meta) — só RECEBE e GUARDA, nunca processa.
// GET  : verificação do webhook (hub.challenge) quando o verify token confere.
// POST : confere X-Hub-Signature-256 sobre o CORPO CRU, grava o JSON em whatsapp_meta_events e responde 200.
//        Quem processa (dedup, URA, status) é o servidor do bot, lendo dessa tabela.
// Deploy: sem verificação de JWT (a Meta não manda JWT):  supabase functions deploy whatsapp-meta-webhook --no-verify-jwt
// Segredos (supabase secrets set): META_APP_SECRET, META_WEBHOOK_VERIFY_TOKEN. SUPABASE_URL e
// SUPABASE_SERVICE_ROLE_KEY já existem no ambiente das Edge Functions.
import { createClient } from "npm:@supabase/supabase-js@2";

const encoder = new TextEncoder();

function toHex(buf: ArrayBuffer): string {
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function validSignature(rawBody: string, header: string | null, secret: string): Promise<boolean> {
  if (!header || !header.startsWith("sha256=") || !secret) return false;
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const expected = toHex(await crypto.subtle.sign("HMAC", key, encoder.encode(rawBody)));
  return safeEqual(expected, header.slice("sha256=".length).toLowerCase());
}

Deno.serve(async (req) => {
  const url = new URL(req.url);

  if (req.method === "GET") {
    const ok = url.searchParams.get("hub.mode") === "subscribe" &&
      url.searchParams.get("hub.verify_token") === Deno.env.get("META_WEBHOOK_VERIFY_TOKEN") &&
      !!Deno.env.get("META_WEBHOOK_VERIFY_TOKEN");
    return ok ? new Response(url.searchParams.get("hub.challenge") ?? "", { status: 200 }) : new Response("forbidden", { status: 403 });
  }

  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });

  const rawBody = await req.text(); // corpo cru: a assinatura é sobre ele, não sobre o JSON reinterpretado
  if (!(await validSignature(rawBody, req.headers.get("x-hub-signature-256"), Deno.env.get("META_APP_SECRET") ?? ""))) {
    return new Response("invalid signature", { status: 401 });
  }

  let payload: unknown;
  try {
    payload = JSON.parse(rawBody);
  } catch {
    return new Response("bad json", { status: 400 });
  }

  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const { error } = await supabase.from("whatsapp_meta_events").insert({ payload });
  if (error) {
    console.error("falha ao gravar evento da Meta:", error.message);
    return new Response("storage error", { status: 500 }); // a Meta reenvia; o dedup é feito por id da mensagem no processamento
  }
  return new Response("ok", { status: 200 });
});
