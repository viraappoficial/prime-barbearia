// Cria o pedido de plano pago pelo site: o cliente logado escolhe plano + barbeiro e recebe o link de pagamento do InfinitePay.
// Lógica pura: o banco e o provedor entram por `deps`. O valor SEMPRE vem do plano no banco; nada de valor vem do navegador.
import type { Provedor } from "../_shared/provedores.ts";

export type Cliente = { id: string; name: string | null; phone: string | null; email: string | null };
export type Plano = { id: number; nome: string; valor: number; ativo: boolean };

export interface Repo {
  cliente(userId: string): Promise<Cliente | null>;
  plano(id: number): Promise<Plano | null>;
  barbeiroExiste(id: string): Promise<boolean>;
  /** cria a assinatura "aguardando pagamento" (troca o pedido pendente anterior). Erro com o texto da regra: "já tem um plano ativo". */
  criarAssinatura(a: { plano_id: number; phone: string; name: string; client_id: string; barber_id: string }): Promise<number>;
  inserirCobranca(c: { id: string; assinatura_id: number; amount: number }): Promise<void>;
  atualizarCobranca(id: string, patch: Record<string, unknown>): Promise<void>;
}
export type Deps = { repo: Repo; provedor: Provedor; urlAviso: string; novoId: () => string; agora: () => Date; log?: (m: string) => void };
export type Resposta = { status: number; body: Record<string, unknown> };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const so = (v: unknown) => String(v ?? "").replace(/\D/g, "");

export async function criarPagamentoPlano(userId: string | null, entrada: { plano_id?: unknown; barber_id?: unknown }, deps: Deps): Promise<Resposta> {
  const { repo, provedor } = deps;
  if (!userId) return { status: 401, body: { erro: "nao_logado" } };
  const planoId = Number(entrada.plano_id), barberId = String(entrada.barber_id ?? "");
  if (!Number.isInteger(planoId) || planoId <= 0 || !UUID.test(barberId)) return { status: 400, body: { erro: "pedido_invalido" } };

  const cli = await repo.cliente(userId);
  if (!cli) return { status: 404, body: { erro: "cliente_nao_encontrado" } };
  const fone = so(cli.phone), foneLocal = fone.length > 11 && fone.startsWith("55") ? fone.slice(2) : fone;
  if (foneLocal.length < 10) return { status: 422, body: { erro: "telefone_obrigatorio" } };

  const pl = await repo.plano(planoId);
  if (!pl || !pl.ativo) return { status: 404, body: { erro: "plano_indisponivel" } };
  if (!(pl.valor > 0)) return { status: 422, body: { erro: "valor_invalido" } };
  if (!(await repo.barbeiroExiste(barberId))) return { status: 404, body: { erro: "barbeiro_invalido" } };

  let assinaturaId: number;
  try {
    assinaturaId = await repo.criarAssinatura({ plano_id: pl.id, phone: foneLocal, name: cli.name?.trim() || "Cliente", client_id: cli.id, barber_id: barberId });
  } catch (e) {
    const m = e instanceof Error ? e.message : String(e);
    if (/plano ativo/i.test(m)) return { status: 409, body: { erro: "ja_tem_plano" } };
    deps.log?.(`criar-pagamento-plano: assinatura recusada: ${m}`);
    return { status: 500, body: { erro: "erro_interno" } };
  }

  const id = deps.novoId();
  await repo.inserirCobranca({ id, assinatura_id: assinaturaId, amount: pl.valor });
  const email = cli.email?.trim() || `plano+${cli.id}@primebarbearia.app.br`;
  const r = await provedor.criarPix(
    { valor: pl.valor, descricao: `Prime Barbearia - ${pl.nome}`, email, nome: cli.name ?? "Cliente", cpf: "", referencia: id, urlAviso: deps.urlAviso, expira: new Date(deps.agora().getTime() + 2 * 3600_000).toISOString() },
    `plano-${id}`,
  );
  if (!r.ok || !r.ticket_url) {
    deps.log?.(`criar-pagamento-plano: o provedor recusou (HTTP ${r.status}): ${r.erro ?? ""}`);
    await repo.atualizarCobranca(id, { status: "cancelado" });
    return { status: 502, body: { erro: "provedor_indisponivel" } };
  }
  await repo.atualizarCobranca(id, { provider_payment_id: String(r.id), ticket_url: r.ticket_url });
  return { status: 200, body: { payment_id: id, amount: pl.valor, plano: pl.nome, ticket_url: r.ticket_url } };
}
