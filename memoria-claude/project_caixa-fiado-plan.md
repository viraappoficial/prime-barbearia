---
name: project-caixa-fiado-plan
description: "Plano futuro pro módulo de Caixa (cofre, sangria, fechamento) e A Prazo/Fiado do Prime Barbearia — levantamento completo em 2026-08-01, ainda não implementado."
metadata:
  node_type: memory
  type: project
  modified: 2026-08-01T00:00:00.000Z
---

**Status:** só levantamento/desenho, nada implementado ainda (2026-08-01). Gabriel pediu pra desenvolver a ideia antes de codar, do mesmo jeito que foi feito com Contas a Pagar. Não repetir esse levantamento quando ele voltar ao assunto — está tudo mapeado abaixo, só perguntar o que mudou/falta e começar.

## Motivação
Gabriel precisa organizar a parte física de dinheiro da barbearia: cofre da empresa, sangria do caixa, fechamento de caixa. Avisou que o caixa pode ficar dias sem fechar (baixa rotatividade de papel-moeda), então o fechamento não pode ser obrigatoriamente diário. No processo, ficou claro que falta uma peça fundamental: **hoje `sales` não guarda forma de pagamento nenhuma** — sem isso não dá pra saber quanto do faturamento foi em dinheiro físico.

## Estado atual do código (levantado 2026-08-01)
- Tabela `sales`: id, barber_id, client_name, appointment_id, service, value, date, time, nota_id (agrupa linhas de uma mesma "nota" — serviço+produtos), qty, type, category, cost, created_at. **Sem campo de forma de pagamento.**
- Inserção de vendas: `baFinalizarCarrinho()` (fluxo Agenda) e atendimento avulso de balcão — ambos chamam `baInsertSales(rows)`. Nenhum pergunta forma de pagamento hoje.
- `expenses` já tem `paid_method` ('dinheiro'/'banco') — só do lado de despesa, não de venda.
- Nenhum conceito de "caixa"/cash register existe hoje — é greenfield total.
- Dashboard/DRE (`baComputeDRE`) só segmentam por tipo de receita (serviço/produto/assinatura) e categoria de despesa — não tem visão dinheiro vs cartão vs pix.
- Menu Gestão → Financeiro já tem: Contas a Pagar, Fornecedores, Plano de contas, Contas bancárias. Caixa e A Prazo devem entrar como novas sub-abas aqui (mesmo padrão `data-fin` + `baFinanceiroTab`).
- Sistema é single-tenant (uma barbearia só, sem `shop_id`), multi-barbeiro (`barbers.role`: admin/barbeiro/vendas — perfil "vendas" é o balcão, atua em nome de outros).
- Login já é via Supabase Auth real (`sb.auth.signInWithPassword`).

## Desenho fechado (decisões do Gabriel, 2026-08-01)

### 1. Forma de pagamento na venda (pré-requisito de tudo)
- Nova tabela de **recebimentos por nota** (não um campo único em `sales`) — permite **split de pagamento** (ex: metade dinheiro, metade pix; ou cartão+cartão). Cada linha: nota_id, forma, valor, NSU (quando aplicável), parcelas (quando aplicável), created_at.
- Formas de pagamento: **Dinheiro, Débito, Crédito (parcela 1-3x por enquanto, expansível depois), Pix QRS (via maquininha — gera NSU/autorizador, aparece no cupom fiscal), Pix direto na chave (sem NSU), A Prazo/Fiado**.
- NSU obrigatório/capturado quando: débito, crédito, ou Pix QRS. Pix direto na chave não tem NSU.
- Escolhida no momento de finalizar o carrinho (Agenda e Atendimento avulso de balcão), tanto faz o fluxo.
- Isso também é o que falta pro plano [[project_conciliacao-financeira-plan]] (taxa real de cartão/pix) — mesma base de dados serve pros dois.

### 2. A Prazo / Fiado
- Confirmado: é fiado tradicional (cliente pessoa física deve, paga depois), não convênio empresarial — só com nome mais bonito ("A Prazo").
- Nova sub-aba **"A Prazo"** em Gestão → Financeiro, par de Contas a Pagar (contas a receber vs. a pagar).
- Cada venda fiado grava: cliente, valor, data, **vencimento padrão +30 dias (editável)**, status (aberto/faturado/pago/atrasado).
- Venda continua aparecendo normal no relatório do barbeiro (isso já funciona, `sales` não muda estrutura pra isso).
- **Tela "Clientes a Prazo"**: lista clientes com saldo aberto, total devido, atrasados destacados.
- **"Fechamento" = gerar fatura**: soma tudo em aberto do cliente, gera fatura, marca como "faturado" (cobrança enviada, ainda não pago).
- **Envio da fatura por WhatsApp**: MVP via link `wa.me` com mensagem pré-preenchida (usuário abre o WhatsApp e manda manualmente) — decidido NÃO ir de WhatsApp Business API agora (exige aprovação Meta, custo mensal, muito mais trabalho pro tamanho do negócio atual).
- **Pagamento parcial da fatura: ainda em aberto, não decidido.** Perguntar quando for implementar.
- **IMPORTANTE — identidade visual da fatura (pedido explícito 2026-08-01):** a fatura NÃO pode ter cara de sistema genérico. Precisa usar a identidade visual completa do Prime: paleta do site (`--verde-neon` #35C558, `--verde-prime` #1E6B33, `--verde-noite` #0B140D, `--grafite` #141715/#1A1E1B, `--prata` #EDEDE8, `--dourado` #C6A75E/#E8D5A4), tipografia Cinzel (display) + Jost (corpo), e o emblema/logo do Prime (`icon-512.png`, ícone circular de linha fina, árvore/sol estilizado) — mesmo padrão visual usado nas peças de Instagram (`memoria-claude` não guarda os PNGs, mas o gerador está em `/tmp/.../scratchpad/media-kit/build.py` daquela sessão, útil de referência pro estilo).

### 3. Risco de comissão sobre fiado (levantado pela Claude, endossado por Gabriel)
- Problema real: se o barbeiro recebe comissão na hora da venda, e a venda é fiado que nunca é paga, a barbearia perde o serviço **e** a comissão.
- Solução: **toggle global** (não por barbeiro — regra de negócio única pra todo mundo) em configuração da barbearia: "Comissão sobre venda fiado" — Paga na hora da venda **vs.** Só paga quando o cliente quitar. Se for a segunda opção, a venda fiado aparece como "pendente" no relatório do barbeiro até a fatura ser marcada como paga, e a comissão entra no cálculo do período em que foi *paga*, não em que foi *vendida*.

### 4. Cofre / Sangria / Fechamento de Caixa
- Cofre da empresa: saldo único (não por loja, sistema é single-tenant).
- Sangria: retirada do caixa pro cofre (ou depósito direto no banco) — valor, data/hora, quem fez, destino.
- Fechamento de caixa: **por período livre**, não obrigatoriamente diário (baixa rotatividade de papel-moeda pode deixar dias sem fechar). Esperado = vendas em dinheiro − despesas pagas em dinheiro − sangrias do período (+ recebimentos de fiado quitados em dinheiro no período — ainda não formalizado no desenho, mas é consequência lógica de fiado ter sua própria tela de "receber": quando o cliente paga o fiado em dinheiro, isso deveria contar como entrada de caixa daquele dia, mesmo não sendo uma "venda nova"). Usuário informa valor contado → sistema mostra sobra/falta.
- Toda ação sensível (abrir caixa, fechar caixa, sangria, editar lançamento de período fechado) exige **reautenticação com login e senha real do admin** — não PIN, não troca de sessão do usuário atual. Implementação técnica: usar uma instância separada do client Supabase só pra chamar `signInWithPassword` de verificação, descartada depois — não mexe na sessão ativa de quem tá logado (ex: perfil "vendas" no balcão).
- Fechamento de caixa **trava** edição/remoção de vendas e despesas em dinheiro daquele período — só reabre com login+senha do admin de novo.

## Ordem de implementação sugerida (não decidida com Gabriel ainda, só uma sugestão de sequência lógica)
1. Forma de pagamento + tabela de recebimentos por nota (pré-requisito de tudo o resto).
2. Cofre/Sangria/Fechamento de Caixa (já dá pra usar só com "dinheiro" funcionando).
3. A Prazo/Fiado + tela Clientes a Prazo + fatura com identidade visual + toggle de comissão.
4. Envio de fatura via wa.me.

## Relação com outros planos
- [[project_conciliacao-financeira-plan]]: taxa real de cartão/pix depende dos mesmos dados de forma de pagamento + NSU que este plano introduz.
- [[project_contas-a-pagar-plan]]: A Prazo é o espelho de Contas a Pagar (a receber vs. a pagar), mesmo padrão de UI.
