// Edge Function criar-pagamento-plano: o site (cliente logado) manda { plano_id, barber_id } e recebe o link de pagamento do InfinitePay.
// Deploy COM verificação de JWT (quem chama é o cliente logado):  supabase functions deploy criar-pagamento-plano
// Variáveis: INFINITEPAY_HANDLE, INFINITEPAY_REDIRECT_URL, INFINITEPAY_TOKEN (só se a conta exigir). Quem paga e quanto é decidido aqui, nunca no navegador.
// Parcelamento: o link do InfinitePay não permite limitar parcelas pela API; o limite de 1x do plano é configurado na conta InfinitePay.
import { createClient } from "npm:@supabase/supabase-js@2";
import { criarPagamentoPlano, type Repo } from "./handler.ts";
import { provedorInfinitePay } from "../_shared/provedores.ts";

const ORIGENS = ["https://primebarbearia.app.br", "https://www.primebarbearia.app.br", "https://staff.primebarbearia.app.br"];
const cors = (req: Request) => ({
  "Access-Control-Allow-Origin": ORIGENS.includes(req.headers.get("origin") ?? "") ? req.headers.get("origin")! : ORIGENS[0],
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin",
});
const URL_BANCO = Deno.env.get("SUPABASE_URL")!;
const db = createClient(URL_BANCO, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const must = <T>(r: { data: T; error: { message: string } | null }): T => { if (r.error) throw new Error(r.error.message); return r.data; };

const repo: Repo = {
  async cliente(userId) { return must(await db.from("clients").select("id,name,phone,email").eq("id", userId).maybeSingle()) as any; },
  async plano(id) { const p = must(await db.from("planos").select("id,nome,valor,ativo").eq("id", id).maybeSingle()) as any; return p ? { ...p, valor: Number(p.valor) } : null; },
  async barbeiroExiste(id) { return !!must(await db.from("barbers").select("id").eq("id", id).maybeSingle()); },
  async criarAssinatura(a) {
    const { data, error } = await db.rpc("vender_plano", { p_plano_id: a.plano_id, p_phone: a.phone, p_name: a.name, p_client_id: a.client_id, p_barber_id: a.barber_id, p_origem: "site", p_forma: "pix", p_pago: false, p_nota_id: null });
    if (error) throw new Error(error.message);
    return Number(data);
  },
  async inserirCobranca(c) { must(await db.from("assinatura_cobrancas").insert(c)); },
  async atualizarCobranca(id, patch) { must(await db.from("assinatura_cobrancas").update(patch).eq("id", id)); },
};

Deno.serve(async (req) => {
  const headers = { ...cors(req), "Content-Type": "application/json" };
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers });
  if (req.method !== "POST") return new Response(JSON.stringify({ erro: "método não permitido" }), { status: 405, headers });
  try {
    // quem é o cliente vem do token dele (JWT), nunca do corpo do pedido
    const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
    const { data: u } = token ? await db.auth.getUser(token) : { data: { user: null } };
    const entrada = await req.json().catch(() => ({}));
    const r = await criarPagamentoPlano(u?.user?.id ?? null, entrada, {
      repo, agora: () => new Date(), novoId: () => crypto.randomUUID(), log: (m) => console.error(m),
      provedor: provedorInfinitePay({ handle: Deno.env.get("INFINITEPAY_HANDLE") ?? "", token: Deno.env.get("INFINITEPAY_TOKEN") || undefined, urlRetorno: Deno.env.get("INFINITEPAY_REDIRECT_URL") || undefined }),
      urlAviso: `${URL_BANCO}/functions/v1/aviso-infinitepay`,
    });
    return new Response(JSON.stringify(r.body), { status: r.status, headers });
  } catch (e) {
    console.error("criar-pagamento-plano:", e instanceof Error ? e.message : e);
    return new Response(JSON.stringify({ erro: "erro_interno" }), { status: 500, headers });
  }
});
