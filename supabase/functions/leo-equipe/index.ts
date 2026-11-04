// Edge Function leo-equipe: o app da equipe chama com { atalho } ou { pergunta, historico } e recebe a resposta do Léo da equipe.
// Deploy COM verificação de JWT (quem chama é alguém logado). Variáveis: ANTHROPIC_API_KEY (segredo; sem ela só os atalhos funcionam).
// Só LÊ: as consultas usam o acesso de quem está logado (RLS), então barbeiro só enxerga o que é dele.
import { createClient } from "npm:@supabase/supabase-js@2";
import { atender, custo, type Controle, type Leitura, type Perfil } from "./handler.ts";

const ORIGENS = ["https://primebarbearia.app.br", "https://www.primebarbearia.app.br", "https://staff.primebarbearia.app.br"];
const cors = (req: Request) => ({
  "Access-Control-Allow-Origin": ORIGENS.includes(req.headers.get("origin") ?? "") ? req.headers.get("origin")! : ORIGENS[0],
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin",
});
const URL_BANCO = Deno.env.get("SUPABASE_URL")!;
const admin = createClient(URL_BANCO, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const MODELO = "claude-haiku-5-5", PRECO = { entrada: 0.1, saida: 0.5 };   // US$ por milhão de tokens

function hojeSP() {
  const p = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Sao_Paulo", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).formatToParts(new Date());
  const g = (t: string) => p.find((x) => x.type === t)?.value ?? "00";
  return { dia: `${g("year")}-${g("month")}-${g("day")}`, hm: `${g("hour")}:${g("minute")}` };
}
const must = <T>(r: { data: T; error: { message: string } | null }): T => { if (r.error) throw new Error(r.error.message); return r.data; };

function leituraDoUsuario(token: string): Leitura {
  const db = createClient(URL_BANCO, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: `Bearer ${token}` } }, auth: { persistSession: false } });
  return {
    async vendas(de, ate) {
      const todas: any[] = [];
      for (let ini = 0; ini < 5000; ini += 1000) {
        const lote = must(await db.from("sales").select("date,value,nota_id,type,barber_id").gte("date", de).lte("date", ate).order("id").range(ini, ini + 999)) as any[];
        todas.push(...lote); if (lote.length < 1000) break;
      }
      return todas;
    },
    async pagamentos(ids) {
      const todas: any[] = [];
      for (let i = 0; i < ids.length; i += 200) todas.push(...(must(await db.from("sale_payments").select("nota_id,method,value").in("nota_id", ids.slice(i, i + 200))) as any[]));
      return todas;
    },
    async agendamentos(dia) { return must(await db.from("appointments").select("day,time,status,iniciado_em,client_name,services,barber_id,payment_status").eq("day", dia)) as any; },
    async assinaturasAtivas() { return must(await db.from("assinaturas").select("plano_nome,client_name,fim,barber_id").eq("status", "ativa").gte("fim", hojeSP().dia)) as any; },
    async nomesBarbeiros() { return Object.fromEntries((must(await db.from("barbers_public").select("id,name")) as any[]).map((b) => [b.id, b.name])); },
  };
}

const controle: Controle = {
  async config() {
    const r = must(await admin.from("whatsapp_ura_settings").select("key,value").in("key", ["leo_equipe_ligado", "leo_equipe_limite_dia", "leo_equipe_teto_mes_usd"])) as any[];
    const m = new Map(r.map((x) => [x.key, x.value]));
    return { ligado: (m.get("leo_equipe_ligado") ?? "true") !== "false", limiteDia: Number(m.get("leo_equipe_limite_dia")) || 30, tetoMesUsd: Number(m.get("leo_equipe_teto_mes_usd")) || 10 };
  },
  async perguntasDoDia(userId, dia) {
    const { count, error } = await admin.from("leo_equipe_uso").select("id", { count: "exact", head: true }).eq("user_id", userId).eq("dia", dia).eq("tipo", "ia");
    if (error) throw new Error(error.message); return count ?? 0;
  },
  async gastoDoMes(mes) {
    const ini = mes + "-01", d = new Date(Date.parse(ini + "T12:00:00Z")); d.setUTCMonth(d.getUTCMonth() + 1);
    const rows = must(await admin.from("leo_equipe_uso").select("custo_usd,tipo").gte("dia", ini).lt("dia", d.toISOString().slice(0, 10))) as any[];
    return { custoUsd: rows.reduce((s, r) => s + Number(r.custo_usd || 0), 0), perguntas: rows.filter((r) => r.tipo === "ia").length };
  },
  async registrar({ userId, dia, tipo, uso }) {
    must(await admin.from("leo_equipe_uso").insert({ user_id: userId, dia, tipo, modelo: uso?.modelo ?? null, entrada_tokens: uso?.entrada ?? 0, saida_tokens: uso?.saida ?? 0, cache_leitura_tokens: uso?.cacheLeitura ?? 0, cache_escrita_tokens: uso?.cacheEscrita ?? 0, chamadas: uso?.chamadas ?? 0, custo_usd: uso?.custoUsd ?? 0 }));
  },
};

const chave = Deno.env.get("ANTHROPIC_API_KEY");
const ia = chave ? {
  async responder({ system, tools, mensagens }: { system: string; tools: any[]; mensagens: any[] }) {
    // cache de prompt: a parte fixa (instruções + ferramentas) é marcada para ser reaproveitada e cobrada bem mais barato nas chamadas seguintes
    const ferramentas = tools.map((t, i) => (i === tools.length - 1 ? { ...t, cache_control: { type: "ephemeral" } } : t));
    const r = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST", headers: { "content-type": "application/json", "x-api-key": chave, "anthropic-version": "2023-06-01" },
      body: JSON.stringify({ model: MODELO, max_tokens: 600, system: [{ type: "text", text: system, cache_control: { type: "ephemeral" } }], tools: ferramentas, messages: mensagens }),
    });
    const j: any = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(`Anthropic HTTP ${r.status}: ${JSON.stringify(j?.error ?? j).slice(0, 200)}`);
    const u = j.usage ?? {};
    const uso = { modelo: MODELO, entrada: u.input_tokens ?? 0, saida: u.output_tokens ?? 0, cacheLeitura: u.cache_read_input_tokens ?? 0, cacheEscrita: u.cache_creation_input_tokens ?? 0, chamadas: 1, custoUsd: 0 };
    uso.custoUsd = custo(uso, PRECO);
    return { stop: j.stop_reason, content: j.content ?? [], uso };
  },
} : null;

Deno.serve(async (req) => {
  const headers = { ...cors(req), "Content-Type": "application/json" };
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers });
  if (req.method !== "POST") return new Response(JSON.stringify({ erro: "método não permitido" }), { status: 405, headers });
  try {
    const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
    const { data: u } = token ? await admin.auth.getUser(token) : { data: { user: null } };
    let perfil: Perfil | null = null;
    if (u?.user) {
      const b = (await admin.from("barbers").select("id,name,role").eq("id", u.user.id).maybeSingle()).data as any;
      if (b) perfil = { id: b.id, nome: String(b.name || "").split(" ")[0] || "equipe", papel: b.role === "admin" ? "admin" : b.role === "vendas" ? "vendas" : "barbeiro" };   // quem não é da equipe (cliente) fica sem perfil e não passa
    }
    const entrada = await req.json().catch(() => ({}));
    const { dia, hm } = hojeSP();
    const r = await atender(perfil, entrada, { leitura: leituraDoUsuario(token), controle, ia, hoje: dia, agoraHm: hm, log: (m) => console.error(m) });
    return new Response(JSON.stringify(r.body), { status: r.status, headers });
  } catch (e) {
    console.error("leo-equipe:", e instanceof Error ? e.message : e);
    return new Response(JSON.stringify({ erro: "erro_interno" }), { status: 500, headers });
  }
});
