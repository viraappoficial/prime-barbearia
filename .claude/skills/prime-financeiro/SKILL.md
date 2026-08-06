---
name: prime-financeiro
description: Workflow financeiro do Prime Barbearia — conciliação bancária, registro de forma de pagamento e NSU por atendimento, cálculo de taxas de cartão, relatórios, contas a pagar e construção de DRE. Use sempre que o usuário pedir para trabalhar em conciliação, extrato bancário, taxas de cartão/NSU, relatório financeiro, contas a pagar ou DRE do Prime.
---

# Prime Barbearia — Modelo Financeiro

Fonte da verdade: `supabase/migrations/` (schema explícito) + tabelas criadas direto no banco antes de existir pasta de migrations (`sales`, `sale_payments`, `expenses`, `fiado_charges`, `taxas_maquininha` — não têm arquivo `.sql` correspondente no repo, só existem no Supabase). Ao investigar uma dúvida de schema que não está documentada aqui, confira o banco direto (`mcp__Supabase__list_tables`) antes de assumir.

## Tabelas e o que cada uma guarda

| Tabela | Guarda | Observação |
|---|---|---|
| `sales` | Uma linha por venda/nota fechada — `barber_id` (FK real), `appointment_id` opcional (liga a venda ao agendamento de origem) | Todo checkout (agendado, encaixe ou avulso) gera venda real aqui — antes de uma correção do roadmap, agendamentos finalizados pelo site "sumiam" financeiramente |
| `sale_payments` | Uma linha por **forma de pagamento** dentro de uma venda — `nota_id`, `barber_id`, `method`, `value`, `parcelas`, `nsu`, `bandeira` | Uma venda pode ter várias linhas (pagamento misto: parte dinheiro, parte cartão) |
| `fiado_charges` | Cobranças "a prazo" — `status`, `paid_at`, `paid_method` | Cliente fatura e paga depois; comissão do barbeiro pode ser configurada pra pagar na hora da venda ou só na quitação |
| `taxas_maquininha` | Taxa % por `forma` (débito/crédito/pix maquininha) × `bandeira` × `parcelas` | Cadastro manual, admin-only — é a base da estimativa de taxa no DRE |
| `expenses` | Despesas — `date`, `category`, `value`, e (desde a migration de contas a pagar) `supplier_id`, `due_date`, `payment_type`, `installment_number/total/group_id`, `status`, `paid_at`, `paid_method`, `bank_account_id` | Alimenta Despesas do mês, Lucro líquido, DRE e Contas a Pagar — é a mesma tabela pros três, sem duplicação |
| `suppliers` | Fornecedores — `name`, `phone`, `website`, `chart_of_account_id` | Vínculo com plano de contas sugere a categoria certa ao lançar uma despesa pra esse fornecedor |
| `bank_accounts` | Contas bancárias — `name`, `agencia`, `conta` | Só serve pra **marcar** de qual conta saiu o pagamento de uma despesa; não sincroniza com banco nenhum |
| `chart_of_accounts` | Plano de contas — `slug`, `name`, `is_taxa_maquininha` | Seed fixo: aluguel, energia, água/internet, salários, produtos e materiais, marketing, software, taxa de maquininha, outros |

Todas as tabelas têm RLS restrita a `role='admin'` em `barbers`, exceto o que já é natural do dono do dado (ex: vendas ficam visíveis pro barbeiro dono via política própria de `sales`, fora do escopo desta skill).

## Como forma de pagamento e NSU são capturados

No fechamento do carrinho, o barbeiro monta uma ou mais **linhas de pagamento** (`baPgtoState.linhas`) até bater o total da venda — cada linha tem `method` (dinheiro/débito/crédito/pix), e quando é cartão, também `bandeira` e `nsu` (texto livre) e, se crédito, `parcelas`. Pagamento em dinheiro com troco desconta o troco do valor final antes de gravar — só o que ficou de fato no caixa vira linha em `sale_payments`. Cada linha confirmada é inserida em `sale_payments` via `baInsertSalePayments`.

**O NSU é só um campo de anotação.** Não existe validação, nem cruzamento automático com operadora — serve pra o barbeiro conseguir localizar o recebimento depois, manualmente, se precisar conferir contra o extrato da maquininha.

## Taxas de maquininha (Financeiro → Taxas de maquininha)

Cadastro manual, admin-only: forma (débito/crédito/pix maquininha) × bandeira × parcelas → taxa %. Usado só pra **estimar** quanto do faturamento em cartão/pix realmente cai líquido — não é a taxa real cobrada, é o que foi cadastrado. Se uma combinação forma/bandeira/parcelas aparece numa venda sem taxa cadastrada, o DRE avisa quantos recebimentos ficaram fora da estimativa (não trava o cálculo, só sinaliza).

## O que "conciliação" significa hoje (e o que ainda não existe)

Não existe importação de extrato bancário (CSV/OFX) nem cruzamento automático com o banco — o próprio código comenta isso explicitamente (`estimativa de taxa de maquininha pro DRE — usa o cadastro, não o extrato real, que ainda não existe`). O que existe hoje, sob o nome de "conciliação":

1. **Fechamento de caixa** (Financeiro → Fechamento) — a conciliação real que existe: soma o esperado em dinheiro (vendas em dinheiro + suprido no período − sangrias) e compara com o valor contado fisicamente na gaveta, mostrando a diferença. Isso é conferência física, não bancária.
2. **Estimativa de taxa de cartão no DRE** — cruza `sale_payments` (o que foi vendido em cada forma/bandeira/parcela) com `taxas_maquininha` (o que foi cadastrado) pra chutar o valor líquido. É estimativa, não conciliação de fato.

Se o usuário pedir "conciliação com extrato bancário" de verdade, isso é feature nova (import de arquivo do banco + matching por valor/data/NSU), não uma tela que já existe — não confundir com o Fechamento de Caixa.

## Contas a Pagar

`expenses` ganhou fornecedor, vencimento (`due_date`), parcelamento (`payment_type='parcelado'` gera N linhas com `installment_group_id` compartilhado, valor dividido com o resto na última parcela) e baixa (`status='pago'`, `paid_at`, `paid_method` dinheiro/banco, `bank_account_id` quando baixado via banco). Despesas lançadas antes dessa migration foram todas marcadas como já pagas (`status='pago'`) no backfill, e despesas sem `due_date` herdaram a própria data de lançamento como vencimento — sem isso elas sumiriam da tela de Contas a Pagar, que filtra por vencimento.

**Comissão de barbeiro como conta a pagar**: Financeiro → Comissões calcula o total vendido num período por barbeiro, permite ajustar o valor manualmente e gera uma `expense` na categoria `comissao` com vencimento definido — mesma tabela, mesmo fluxo de baixa das outras contas.

**Fluxo de caixa projetado** (Financeiro → Fluxo): cruza Contas a Pagar (saídas futuras) com A Prazo a receber (entradas futuras) pra estimar sobra/falta em 7/15/30/60 dias. Não inclui saldo bancário real — só o que já está em caixa hoje, projetado.

## Relatórios

Relatório mensal exportável em PDF via impressão (`#ba-report-print`), detalhado por barbeiro/cliente/despesa, com a paleta clara de papel documentada em `prime-design` (tokens `--rp-*`) — não a paleta escura do app. Tem também um resumo compartilhável por WhatsApp. Exportação em XLSX foi deliberadamente deixada de fora (só valeria a pena se surgisse a necessidade real de manipular os números numa planilha).

## DRE (Financeiro → DRE, admin-only)

Cascata em regime de **competência** (conta no mês do atendimento/venda, não do pagamento), calculada por `baComputeDRE(year, month)`:

1. **Receita**: serviços avulsos + assinaturas + produtos vendidos → Receita total
2. **Lucro bruto** = Receita total − comissão dos barbeiros − CMV (custo dos produtos vendidos) − taxa de maquininha lançada manualmente (despesa da categoria `taxa_maquininha`) − taxa de maquininha estimada pelo cadastro (a estimativa de `taxas_maquininha` × `sale_payments`, pra não contar a taxa duas vezes se ela também foi lançada manualmente como despesa)
3. **Lucro líquido** = Lucro bruto − despesas operacionais (todas as `expenses` exceto `taxa_maquininha` e `comissao`, que já entraram antes)
4. Margem líquida = Lucro líquido / Receita total

Compara sempre com o mês anterior (variação %). Não faz nenhum cálculo de imposto — isso é dito explicitamente no rodapé do relatório exportado. Exportável em PDF com a mesma paleta de papel dos outros relatórios.

## O que NÃO fazer

- Não tratar `bank_accounts` como se sincronizasse com um banco de verdade — é só uma etiqueta pra saber de onde saiu o dinheiro de uma baixa.
- Não confundir Fechamento de Caixa (conferência física de dinheiro) com conciliação bancária (que ainda não existe).
- Não somar a taxa de maquininha duas vezes no DRE — a estimativa por cadastro e o lançamento manual da despesa são mantidos separados de propósito, pra não distorcer o lucro bruto quando os dois existirem juntos.
- Não esquecer o `due_date` ao criar uma despesa nova — sem ele, ela não aparece em Contas a Pagar.
