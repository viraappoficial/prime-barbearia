# Decisões: planos, pagamento online, CRM e Atendimento

Notas da conversa de 30/10 a 04/11/2026. Serve para retomar sem repetir. Os mockups estão em `docs/mockups/`
(abrem direto no navegador). O que já está no ar e o que é só proposta estão separados abaixo.

## Já construído e no ar

- **Pagamento online (InfinitePay):** link de checkout pelo site, aviso (webhook) com conferência, baixa automática.
  A função `aviso-infinitepay` (v2) guarda se o cliente pagou em Pix ou cartão e em quantas vezes (`appointment_payments.capture_method`, `installments`).
  Pagamento adiantado: botão "Pagar agora", retomar o checkout, reagendar mantendo o pago, selo "Pago".
- **Taxas** (Financeiro › Taxas de maquininha), em duas tabelas (`taxas_maquininha.canal`):
  - Pagamento online (link do site e do Léo): crédito 1x a 12x, de 5,49% a 18,29%. Pix online ainda sem taxa cadastrada.
  - InfiniteTap / maquininha: débito 2,29% e crédito 1x a 12x, para Visa, Mastercard, Elo, Amex e Outra.
- **Conciliação** (Financeiro): pagamentos online do mês, maquininha do mês e conferência com o CSV da InfinitePay (por NSU ou por valor e data).
  Ainda não foi testada com um relatório real da InfinitePay.
- **Planos** (Financeiro › Planos): o admin cadastra assinatura que já existia e ajusta dias restantes, usos e "já foi pago".
  Bronze R$ 99,90, Prata R$ 189,90, Ouro R$ 289,90. Os 9 clientes Prata migrados estão ativos, com saldo cheio e marcados como não pagos.
- **Comissão por uso:** a mensalidade não gera comissão; cada uso do plano paga ao barbeiro que atendeu, pelo valor do item
  (`plano_itens.valor_unit`, editável em Financeiro › Planos). O faturamento entra uma vez, no pagamento do plano.
  Ajuste manual de uso feito pelo admin não gera comissão.
- **CRM** (Gestão › CRM, só admin): ritmo de cada cliente, plano e saldo, histórico e mensagem pelo WhatsApp da Prime.
  A mensagem entra na fila do bot com `origem = 'crm'` e segue as proteções do número (teto por hora e por dia, intervalo, horário, quem pediu para parar).
- **Léo com planos** (código mesclado; o Léo continua desligado): conhece o plano e o saldo, pergunta o que o cliente vai usar,
  atende só com o barbeiro do plano e pede autorização ao Nathan para outro barbeiro.
- **Login do Prime Staff** com o emblema desenhado em ouro.

## Regras decididas

- **Saldo do plano:** o que sobra no fim dos 30 dias se perde (não acumula e não paga comissão).
- **Plano é vinculado ao barbeiro que fechou:** se fechou com o Nathan, quem corta é o Nathan. Miguel tem 50% de comissão.
- **Outro barbeiro no plano:** só o admin autoriza. O Léo manda a pergunta ao Nathan (número 554491784802); ele responde SIM ou NÃO
  (só vale a resposta desse número; 15 minutos sem resposta equivalem a NÃO). A recusa ao cliente é sempre gentil e fala das "normas do plano".
- **Plano precisa ser pago:** até o fim do primeiro atendimento ou antes, pelo checkout. Se o cliente não pagar, o barbeiro decide no fechamento:
  cobrar o plano ou "cobrar avulso" (o plano pendente é cancelado e o serviço volta ao preço normal). Não há cancelamento automático por prazo.
- **Cada item do plano é independente:** o cliente pode marcar só corte, só barba etc. Combos descontam um de cada item.
- **Não oferecer parcelamento** no pagamento online; o texto da tela de pagamento fala em Pix, cartão e Apple Pay.
- **CRM:** o botão de WhatsApp sai pelo WhatsApp da Prime (WAHA), não por `wa.me`.

## Proposta aprovada em desenho, ainda NÃO construída

Mockups em `docs/mockups/`. O que se disse: "a proposta ficou incrível; não vamos mudar agora".

- **Agenda › ficha do atendimento com quatro botões:** Abrir carrinho, Chamar cliente, Remarcar, Cancelar atendimento.
- **Abrir carrinho:** leva à aba **Atendimento** (a mesma tela de hoje: 1 Cliente com busca, 2 Quando e quem, 3 Adicionar, 4 Comanda)
  com a venda já pronta (cliente, barbeiro, data e horário, serviços, o que o plano cobre) e uma linha nova "Já pago online" abatendo o valor.
  Uma aba "Em atendimento" lista os carrinhos abertos.
- **Receber:** no computador, painel à direita (padrão do app, que tem menu lateral); no celular, tela cheia.
  Formas de pagamento como hoje: Dinheiro, Débito, Crédito, Pix (maquininha), Pix (chave), A Prazo; Pix online entra sozinho e abatido.
- **Finalização:** confirmação antes de gravar, tela de concluído (venda no caixa, atendimento concluído, baixa do plano, pagamento online ligado à venda)
  e casos especiais (caixa fechado, plano não pago, a prazo, atendimento já finalizado).
- **Cliente (site):** topo da página inicial com o emblema, agendamento com resumo fixo e cartão do plano com o saldo.
- **Equipe:** tela "Hoje" e agenda como linha do tempo; abertura do app e telas vazias com o emblema.
- **Analista** (aba da Gestão): só ideia, não será construído agora.

Ordem sugerida quando retomar: (1) Abrir carrinho com a venda pronta e o abatimento do pago online (pequeno e evita cobrança duplicada),
(2) aba "Em atendimento", (3) visual novo do Atendimento e a finalização, (4) planos no site (saldo, escolha do plano, pagamento do plano), (5) o resto.

## Em aberto

- Parcelas do crédito: manter 1x a 3x (como a tela tem hoje) ou ir até 12x (as taxas da InfiniteTap vão até 12x)?
- A tela "Hoje": item novo no menu lateral ou só a tela inicial ao entrar?
- Aviso antes do plano vencer (quantos dias antes?) e renovação do mês seguinte (link manual?).
- O plano pendente deve ser cancelado sozinho se o cliente cancelar ou faltar ao primeiro atendimento?
- Taxa do Pix online (InfinitePay) para cadastrar nas taxas.
- Conciliação: testar com um relatório real da InfinitePay; trocar a chave da InfinitePay que foi colada no chat.
- Léo: continua **desligado** (`bot_enabled=false`) e a entrada do Zap cortada (`ai_inicio=2099`). Falta a trava para não responder contatos pessoais,
  o indicador de status do Léo no app e o teste real do link de pagamento e da autorização do Nathan.
- Planos no site e checkout de plano pela InfinitePay ainda não existem.
