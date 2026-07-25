---
name: project-conciliacao-financeira-plan
description: "Plano futuro de conciliação financeira (taxas reais de maquininha/Pix por NSU/E2E ID) e base de DRE pro Prime Barbearia — ainda não iniciado, aguardando dados de taxas."
metadata: 
  node_type: memory
  type: project
  originSessionId: 276cc831-811b-45dd-a594-f885a50f232f
  modified: 2026-07-24T20:05:48.758Z
---

Gabriel quer evoluir o financeiro do Prime pra rastrear com precisão o lucro líquido real, descontando taxa real de pagamento (não estimada), com base num documento que ele escreveu: `prime-conciliacao-financeira.md` (na Área de Trabalho dele, OneDrive SM FARMA).

**Escopo definido no documento (2026-07-24):**
1. Venda passa a gravar: forma de pagamento (dinheiro/pix/débito/crédito + parcelas), identificador único (NSU pro cartão, E2E ID pro Pix), e a taxa aplicada NO MOMENTO do lançamento (travada — não referencia a tabela de taxas "ao vivo", mesmo padrão já usado pro histórico de preço de produto/serviço no app, pra não alterar retroativamente lucro de meses já fechados).
2. Nova tabela `taxas_bandeira` (bandeira × tipo × nº parcelas → %), editável pelo admin, mesmo padrão de outros cadastros do Prime (cupons, produtos, etc.).
3. Conciliação diária: upload de extrato (CSV/XLSX) da maquininha ou Pix, cruza por identificador único com as vendas lançadas, taxa real = (bruto−líquido)/bruto vem pronta do extrato. Resultado em 3 grupos: bateu / só no Prime / só no extrato. Fecha o dia como "conciliado" pra travar recálculo.
4. Dashboard de lucro do dia passa a mostrar status por forma de pagamento: dinheiro sempre confirmado, pix/cartão confirmado só se já conciliado, senão estimado pela tabela de taxas.
5. Isso tudo já deixa a base pronta pra um DRE de período de verdade depois (receita bruta → deduções de taxa → receita líquida → custo (comissão+CMV) → despesas → lucro líquido).

**Por que isso importa:** [[project_backend-migration-plan]] documenta a migração de dados pra Supabase; esse plano de conciliação é a PRÓXIMA camada em cima disso — financeiro real, não só histórico de venda.

**Status:** Gabriel vai mandar dois relatórios de exemplo (cartão e Pix) pra eu extrair a tabela de taxas real e entender o formato de cada um, em vez de ele digitar tudo manualmente. Nada foi implementado ainda — só o levantamento do plano.

**Ajuste levantado em 2026-07-24 (importante pro design da conciliação de Pix):** o relatório de Pix provavelmente vai ser o **extrato bancário comum** (não um relatório Pix dedicado do banco/gateway), e extrato bancário genérico normalmente NÃO mostra o E2E ID completo — só descrição tipo "PIX RECEBIDO — Fulano", valor e horário. Se for esse o caso quando o relatório chegar, a conciliação de Pix não vai poder casar por identificador exato como o cartão (NSU) — vai precisar casar por **valor + data/hora aproximada**, com o risco conhecido de ambiguidade (dois clientes pagando o mesmo valor no mesmo dia). Confirmar isso de fato quando o relatório de Pix chegar, antes de implementar a lógica de matching.

**Como aplicar:** quando ele voltar a esse assunto, não repetir o levantamento de requisitos — já está tudo mapeado acima. Esperar os dois relatórios de exemplo, extrair a tabela de taxas de lá, confirmar se Pix realmente não tem E2E ID visível, e começar pelo passo 1 (forma de pagamento + identificador na venda).

**Confirmado/corrigido em 2026-07-24 — escopo de dinheiro:** dinheiro ENTRA SIM no DRE como receita normalmente (óbvio — foi vendido). O que fica fora de escopo é só a **conciliação externa** (comparar com extrato bancário) — isso sim não se aplica, porque não existe identificador nenhum pra cruzar, e não importa o destino físico da nota depois (guardada, trocada, depositada ou não, isso é fluxo de caixa/tesouraria, não afeta a receita já reconhecida). Dinheiro fica sempre "confirmado" no sistema só pela confiança no lançamento manual — sem prova documental. Gabriel quer poder ver o **breakdown por forma de pagamento**: Dinheiro X + Cartão X + Pix X = Total — isso vem de graça assim que o campo forma de pagamento existir na venda (é só agrupar/somar por forma de pagamento num período, sem trabalho extra). Uma etapa futura opcional de "fechamento de caixa manual" (já citada no doc original) resolveria a rastreabilidade do dinheiro físico se um dia for necessário, mas não é prioridade.

**Confirmado em 2026-07-24 — onde entra o seletor de forma de pagamento no código:** o campo dinheiro/pix/débito/crédito(+parcelas) vai entrar na hora de FINALIZAR a venda, que no index.html hoje já existe em dois pontos (sem esse campo ainda):
- `baFinalizarCarrinho()` — fecha o carrinho de um atendimento agendado (barbeiro clicou "Iniciar" antes)
- `baAtRegistrar()` — atendimento avulso de balcão (walk-in), incluindo o agendamento retroativo que ele cria quando tem serviço + cliente vinculado
Os dois criam linhas na tabela `sales` (via `baInsertSales`/`baSaleToRow`/`baSaleFromRow`, que já tem o padrão de mapear camelCase↔snake_case). Quando for implementar, a forma de pagamento + identificador (NSU/E2E ID) + taxa aplicada entram como campos novos nessa mesma tabela `sales`, preenchidos nesses dois pontos de finalização.

**Adicionado em 2026-07-24 — nova aba "Lançamentos" (admin):** além do lançamento em si, precisa de uma tela separada pro admin **ver e editar** vendas já lançadas (corrigir forma de pagamento, valor, identificador NSU/E2E ID digitado errado, etc.), sempre organizada/filtrada por data. Vai ser útil especialmente pra corrigir os casos que a conciliação apontar como "só no Prime" ou divergência. Provavelmente entra como mais uma aba dentro de Gestão ou Dashboard, seguindo o mesmo padrão visual das outras (Cupons, Instagram, Equipe, Produtos) — lista filtrável por data com edição inline ou modal.

**Confirmado em 2026-07-24 — trilha de auditoria nas edições:** Gabriel gostou e confirmou — toda edição manual de um lançamento (na aba "Lançamentos" acima) precisa deixar rastro (quem editou, quando, valor/campo original → novo), em vez de sobrescrever silenciosamente. Isso importa especialmente pra lançamento de um dia já conciliado/fechado: editar não pode simplesmente destravar o dia sem mais nem menos — precisa registrar a mudança de forma auditável. Provavelmente uma tabela `sales_edit_log` (ou similar) guardando o histórico, e a UI mostrando esse histórico junto da venda editada.

**Confirmado em 2026-07-24 — campos de cartão na venda:** quando forma de pagamento = cartão, os campos são **administradora** (a maquininha/processadora — Stone, Cielo, Rede, GetNet etc.), **parcelas** e **NSU**.

**Resolvido em 2026-07-24 — tabela de taxas é por ADMINISTRADORA, não bandeira:** Gabriel confirmou — a tabela de taxas (antes chamada `taxas_bandeira` no doc original) na verdade é um **cadastro de administradora**: nome da administradora, parcelas, taxa (%). CRUD completo (criar e editar), mesmo padrão dos outros cadastros do Prime. Isso substitui a ideia de "taxa por bandeira" — não entra bandeira (Visa/Master/Elo) nessa conta, só administradora × parcelas → taxa.

**Confirmado em 2026-07-24 — sinalização visual de divergência na conciliação:** quando um lançamento não bater na conciliação (grupo "só no Prime" ou "só no extrato"), a linha precisa ficar destacada visualmente (vermelho ou outra cor de alerta) na tela — não só listada num grupo separado. Fluxo esperado: pessoa vê o destaque → abre a venda na aba Lançamentos → corrige o que tava errado (ex: administradora lançada errada) → reprocessa a conciliação → agora bate. Gabriel reconhece explicitamente que isso não é 100% automático — quem for conciliar precisa ser analítico, revisando os casos divergentes um a um; a IA/sistema só aponta o que não bateu, não resolve sozinho.

**Confirmado em 2026-07-24 — conciliação é diária, e vale um lembrete:** Gabriel confirmou que a intenção é conciliar TODO dia (não semanal/mensal) — faz sentido porque o repasse da maquininha normalmente cai em D+1, e pegar divergência no dia seguinte é muito mais fácil que deixar acumular. Ideia aceita pra anotar (não implementar ainda): um lembrete/notificação tipo "você tem X dias sem conciliar" pra reforçar o hábito diário e evitar acúmulo.
