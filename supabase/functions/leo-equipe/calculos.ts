// Contas do Léo da equipe. TODA conta é feita aqui, pelo sistema: a IA só escreve a resposta com os números que estas funções devolvem.
export type Venda = { date: string; value: number; nota_id: number | null; type: string | null; barber_id: string | null };
export type Pagamento = { nota_id: number; method: string; value: number };
export type Agendamento = { day: string; time: string; status: string; iniciado_em: string | null; client_name: string | null; services: string[] | null; barber_id: string | null; payment_status: string | null };
export type Assinatura = { plano_nome: string; client_name: string; fim: string; barber_id: string | null };

export const FORMAS: Record<string, string> = { dinheiro: "Dinheiro", debito: "Débito", credito: "Crédito", pix_qrs: "Pix (maquininha)", pix_direto: "Pix (chave)", pix_online: "Pix online", a_prazo: "A prazo" };
const r2 = (n: number) => Math.round(n * 100) / 100;
export const dinheiro = (n: number) => "R$ " + r2(n).toFixed(2).replace(".", ",").replace(/\B(?=(\d{3})+(?!\d))/g, ".");

const somaDias = (dia: string, n: number) => new Date(Date.parse(dia + "T12:00:00Z") + n * 86400000).toISOString().slice(0, 10);
const brData = (d: string) => `${d.slice(8, 10)}/${d.slice(5, 7)}`;
export const DIAS_PT = ["domingo", "segunda", "terça", "quarta", "quinta", "sexta", "sábado"];
export const diaSemana = (d: string) => DIAS_PT[new Date(d + "T12:00:00Z").getUTCDay()];

export type Periodo = "hoje" | "ontem" | "semana" | "mes";
/** Intervalo [de, ate] (inclusive) e o rótulo de cada período, em datas de São Paulo. Semana = de segunda até hoje. */
export function intervalo(periodo: Periodo, hoje: string): { de: string; ate: string; rotulo: string } {
  if (periodo === "ontem") { const d = somaDias(hoje, -1); return { de: d, ate: d, rotulo: `Ontem (${brData(d)})` }; }
  if (periodo === "semana") {
    const dow = new Date(hoje + "T12:00:00Z").getUTCDay(), voltar = dow === 0 ? 6 : dow - 1;
    const de = somaDias(hoje, -voltar); return { de, ate: hoje, rotulo: `Esta semana (${brData(de)} a ${brData(hoje)})` };
  }
  if (periodo === "mes") return { de: hoje.slice(0, 8) + "01", ate: hoje, rotulo: `Este mês (${brData(hoje.slice(0, 8) + "01")} a ${brData(hoje)})` };
  return { de: hoje, ate: hoje, rotulo: `Hoje (${brData(hoje)})` };
}

export type Financeiro = { total: number; vendas: number; porForma: { forma: string; rotulo: string; valor: number }[]; porDia: { dia: string; valor: number }[]; porBarbeiro: { barbeiro: string; valor: number }[]; semPagamentoLancado: number };

/** Faturamento = soma das vendas lançadas (mensalidade de plano entra; uso de plano vale R$ 0). Formas vêm dos pagamentos das mesmas notas. */
export function financeiro(vendas: Venda[], pagamentos: Pagamento[], nomes: Record<string, string> = {}): Financeiro {
  const total = r2(vendas.reduce((s, v) => s + Number(v.value || 0), 0));
  const notas = new Set(vendas.filter((v) => v.nota_id != null && Number(v.value) > 0).map((v) => v.nota_id));
  const deNotas = pagamentos.filter((p) => notas.has(p.nota_id));
  const forma = new Map<string, number>();
  deNotas.forEach((p) => forma.set(p.method, (forma.get(p.method) ?? 0) + Number(p.value || 0)));
  const dia = new Map<string, number>(), barb = new Map<string, number>();
  vendas.forEach((v) => {
    dia.set(v.date, (dia.get(v.date) ?? 0) + Number(v.value || 0));
    const nome = (v.barber_id && nomes[v.barber_id]) || "—"; barb.set(nome, (barb.get(nome) ?? 0) + Number(v.value || 0));
  });
  const pagoTotal = deNotas.reduce((s, p) => s + Number(p.value || 0), 0);
  return {
    total, vendas: notas.size,
    porForma: [...forma.entries()].map(([f, valor]) => ({ forma: f, rotulo: FORMAS[f] ?? f, valor: r2(valor) })).sort((a, b) => b.valor - a.valor),
    porDia: [...dia.entries()].map(([d, valor]) => ({ dia: d, valor: r2(valor) })).sort((a, b) => a.dia.localeCompare(b.dia)),
    porBarbeiro: [...barb.entries()].map(([barbeiro, valor]) => ({ barbeiro, valor: r2(valor) })).sort((a, b) => b.valor - a.valor),
    semPagamentoLancado: r2(Math.max(0, total - pagoTotal)),
  };
}

export type Dia = { total: number; concluidos: number; emAtendimento: number; naFila: number; pendentes: number; naoVeio: number; cancelados: number; proximo: { hora: string; cliente: string; servicos: string; barbeiro: string; pagoOnline: boolean } | null; porBarbeiro: { barbeiro: string; total: number; faltam: number }[] };

/** Atendimentos de um dia. "Faltam" = confirmados ou pendentes que ainda não começaram. Cancelados não entram no total. */
export function atendimentos(lista: Agendamento[], agoraHm: string, nomes: Record<string, string> = {}): Dia {
  const ativos = lista.filter((a) => a.status !== "cancelado" && a.status !== "nao_compareceu");
  const abertos = ativos.filter((a) => (a.status === "confirmado" || a.status === "pendente") && !a.iniciado_em).sort((a, b) => a.time.localeCompare(b.time));
  const prox = abertos.find((a) => a.time >= agoraHm) ?? abertos[0] ?? null;
  const por = new Map<string, { total: number; faltam: number }>();
  ativos.forEach((a) => {
    const n = (a.barber_id && nomes[a.barber_id]) || "—", x = por.get(n) ?? { total: 0, faltam: 0 };
    x.total++; if (abertos.includes(a)) x.faltam++; por.set(n, x);
  });
  return {
    total: ativos.length,
    concluidos: ativos.filter((a) => a.status === "concluido").length,
    emAtendimento: ativos.filter((a) => a.status === "confirmado" && !!a.iniciado_em).length,
    naFila: abertos.length,
    pendentes: abertos.filter((a) => a.status === "pendente").length,
    naoVeio: lista.filter((a) => a.status === "nao_compareceu").length,
    cancelados: lista.filter((a) => a.status === "cancelado").length,
    proximo: prox ? { hora: prox.time, cliente: prox.client_name || "Cliente", servicos: (prox.services ?? []).join(" + "), barbeiro: (prox.barber_id && nomes[prox.barber_id]) || "", pagoOnline: prox.payment_status === "pago" } : null,
    porBarbeiro: [...por.entries()].map(([barbeiro, v]) => ({ barbeiro, ...v })).sort((a, b) => b.total - a.total),
  };
}

export function planosAtivos(lista: Assinatura[], nomes: Record<string, string> = {}) {
  const porPlano = new Map<string, number>();
  lista.forEach((a) => porPlano.set(a.plano_nome, (porPlano.get(a.plano_nome) ?? 0) + 1));
  const vencendo = lista.filter((a) => a.fim).sort((a, b) => a.fim.localeCompare(b.fim)).slice(0, 5).map((a) => ({ cliente: a.client_name, plano: a.plano_nome, ate: a.fim, barbeiro: (a.barber_id && nomes[a.barber_id]) || "" }));
  return { total: lista.length, porPlano: [...porPlano.entries()].map(([plano, qtd]) => ({ plano, qtd })), proximosAVencer: vencendo };
}
