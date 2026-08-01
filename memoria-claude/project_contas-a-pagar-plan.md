---
name: project-contas-a-pagar-plan
description: "Módulo de Contas a Pagar do Prime Barbearia (fornecedor, vencimento, plano de contas, contas bancárias, pago/pendente) — IMPLEMENTADO (2026-07-29 a 2026-08-01)."
metadata: 
  node_type: memory
  type: project
  originSessionId: 276cc831-811b-45dd-a594-f885a50f232f
  modified: 2026-08-01T00:00:00.000Z
---

**STATUS (atualizado 2026-08-01): IMPLEMENTADO.** O que estava listado abaixo como "levantamento, nada implementado" foi construído entre os commits `4a2d3b7`..`82f201a`: schema completo (fornecedores, plano de contas, contas bancárias com agência/conta), tela dedicada de Contas a Pagar (unificada com o antigo formulário de Despesas), botão de marcar como pago, correção de policy de UPDATE em `expenses` (faltava e bloqueava marcar como pago), e tudo agrupado numa aba **Financeiro** dentro de Gestão. Polimentos visuais recentes: Plano de Contas / Fornecedores / Contas Bancárias viraram tabelas, Contas a Pagar virou cartão com hierarquia clara, cores/estilo dos links de ação ajustados. Não repetir o levantamento abaixo — está tudo entregue; só perguntar o que falta ou o que Gabriel quer evoluir a partir daqui.

**Levantamento original (2026-07-24, mantido como histórico):**

Gabriel quer evoluir a aba de despesas do Prime (hoje: nome, valor, data, categoria — simples) pra um módulo de **Contas a Pagar** nos moldes de um ERP de verdade. Ele mandou prints do sistema Hiper (Financeiro → Contas a Pagar) como referência visual/funcional: tela de listagem com Operação Nº, Data Lanç., Vencimento, Fornecedor, Histórico, Plano de Conta, Valor Bruto, Desconto, Encargo, Valor Baixa, Saldo, D/C — e um modal "Incluir Lançamento" com esses campos + Tipo de Pagto (Normal/Parcelado) + checkbox "Pago".

**Escopo levantado em 2026-07-24 (ainda não implementado, só o desenho):**
1. **Fornecedor** — novo cadastro pra vincular cada despesa a quem a barbearia deve. Campos confirmados em 2026-07-24: **nome** (obrigatório), **telefone** e **site** (opcionais). CRUD completo confirmado — criar (inclusive "na hora" direto do formulário de lançamento, mesmo padrão de outros cadastros do Prime) e **editar** depois de cadastrado.
2. **Plano de conta** — o que já existe hoje como `category` fixa (aluguel, energia, água/internet, salários, produtos, marketing, software, taxa_maquininha, outros) — mas possivelmente precisa virar um cadastro editável pelo admin em vez de lista fixa no código, igual outros cadastros do Prime (cupons, produtos).
3. **Data de lançamento ≠ Data de vencimento** — hoje `expenses.date` é uma coisa só; separar as duas (quando foi lançado vs. quando vence).
4. **Tipo de pagamento**: normal ou parcelado (com nº de parcelas) — hoje não existe parcelamento nenhum.
5. **Status pago/pendente** — hoje despesa lançada já conta como gasto na hora; precisa virar um estado (pago vs. em aberto), com um botão "Marcar como pago" que pede: quando foi pago, e **como** (dinheiro ou banco).
6. **Instituição financeira** — novo cadastro das contas bancárias da empresa, selecionável na hora de marcar como pago (quando for banco).
7. **Aba com filtro** — por fornecedor, plano de conta, período, pago/pendente — mostrando total **devido** (em aberto) + total **pago/faturado**, no estilo do rodapé do Hiper (Total Bruto / Total Baixa / Total Saldo).

**Relação com o outro plano:** [[project_conciliacao-financeira-plan]] cobre o lado da RECEITA (vendas, taxa real de cartão/pix, DRE). Este aqui cobre o lado da DESPESA (contas a pagar de verdade). Os dois juntos fecham o financeiro completo do Prime rumo a um DRE de verdade.

**Status:** só levantamento de requisitos, nada implementado. Gabriel disse explicitamente "deixa de molde" — não começar a codar ainda, ele tem outras questões em mente antes. Não repetir esse levantamento quando ele voltar ao assunto — já está tudo mapeado acima, só perguntar o que mudou/o que falta e começar.
