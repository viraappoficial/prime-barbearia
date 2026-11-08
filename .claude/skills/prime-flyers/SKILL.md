---
name: prime-flyers
description: Assistente de criação de flyers e material promocional pro Prime Barbearia (banner de porta, post de Instagram, story, impresso, catálogo/menu/planos). Use quando o usuário pedir pra criar um flyer, banner, cartaz, arte de divulgação, peça pra Instagram/WhatsApp, ou material promocional da Prime. Conduz uma entrevista curta antes de desenhar, consulta prime-design + prime-design-evolucao, usa os flyers reais em Flayers/ como referência, e exporta a peça final como PNG pronto pra usar.
---

# Prime Barbearia — Assistente de Flyers

Ferramenta pra criar material promocional novo (flyer, banner, post) mantendo a
identidade visual real da Prime — não uma peça genérica "de barbearia qualquer".

## REGRA CRÍTICA — nunca exportar pra `/tmp`

**A imagem exportada (PNG) precisa SEMPRE ficar dentro de `Flayers/`,
nunca em `/tmp` ou qualquer pasta fora do repositório** — isso vale desde o
primeiro rascunho, não só na versão aprovada. O ViraDeck só consegue mostrar
a prévia pro Gabriel de arquivos que estão dentro do projeto; qualquer coisa
em `/tmp` fica invisível pra ele, mesmo que você descreva o resultado em
texto.

Use o nome final da peça desde a primeira exportação (ex:
`Flayers/Promoção Dia dos Pais.png`) e reexporte por cima dele a cada ajuste
— não precisa de pasta de rascunho separada. O HTML de origem pode ficar em
qualquer lugar (ele não precisa ser visto), mas o `.png` sempre em `Flayers/`.

Toda vez que você usar o `Read` pra conferir a própria imagem, ou rodar o
`export-html.js`, o ViraDeck já mostra a prévia pro Gabriel automaticamente
— não é preciso (mas não atrapalha) incluir `![preview](Flayers/<nome>.png)`
na resposta também.

## Antes de desenhar qualquer coisa

1. Ler os 6 flyers já existentes em `Flayers/` — são a referência de estilo e
   formato que já funcionou antes, não reinventar do zero.
2. Consultar `prime-design` (tokens fixos: cores, tipografia, glass, sombras) —
   **nunca inventar hex novo**.
3. Consultar `prime-design-evolucao` (direção criativa: referência no mundo
   real da barbearia, um elemento assinatura por peça, checagem do genérico).
4. Se precisar lembrar do posicionamento/público da Prime, ver `prime-contexto`.

## Entrevista obrigatória (não pule pra gerar direto)

Perguntar em poucas perguntas objetivas, não um formulário longo:

1. **Objetivo** — promoção nova, serviço específico, evento, campanha sazonal
   (Dia dos Pais, Natal etc.), ou peça institucional?
2. **Oferta** — qual serviço/produto, preço, desconto ou condição, validade.
3. **Destino** — onde essa peça vai ser usada? (decide tamanho e proporção
   automaticamente, ver tabela abaixo — não perguntar pixel, perguntar o
   destino em linguagem normal)
4. **Chamada pra ação** — agendar pelo app, WhatsApp, código de desconto?

## Formatos conhecidos (decide sozinho a partir do destino)

| Destino | Dimensão final (px) | Proporção | Observação |
|---|---|---|---|
| Post Instagram/Facebook (feed) | 1080×1350 | 4:5 | Mesma proporção dos flyers já existentes em `Flayers/` |
| Post quadrado | 1080×1080 | 1:1 | Quando pedir "quadrado" ou não especificar rede |
| Story / WhatsApp status | 1080×1920 | 9:16 | Vertical cheio de tela |
| Banner de porta física | 2406×807 | ~3:1 | Já estabelecido em `Flayers/Banner porta.png` |
| Impresso A4 | 2480×3508 | A4 @300dpi | Qualidade de impressão real, não tela |
| Catálogo/Menu/Planos (estilo existente) | 1206×1506 | 4:5 | Mesmo padrão de `Flayers/Catalogo 1.png` etc. |

Se o destino pedido não bater com nenhuma linha, usar o mais próximo em
proporção e avisar qual foi escolhido.

## Processo de design

1. Nomeie o trabalho em uma frase (o que essa peça precisa fazer a pessoa
   sentir/fazer).
2. Escolha o elemento assinatura do mundo da barbearia (navalha, poste,
   comanda de papel, espelho, textura de couro/mármore/latão — ver
   `prime-design-evolucao`) e justifique por que pertence a essa peça
   específica.
3. Checagem do genérico: esse layout serviria pra "salão de beleza qualquer"
   só trocando a cor? Se sim, refaça.
4. Escreva o HTML/CSS usando só os tokens de `prime-design`, com `body` já no
   tamanho exato da tabela acima (`width`/`height` em px, sem `max-width`).
5. Exporte a peça pra PNG **dentro da pasta `Flayers/`** (mesmo em rascunho —
   reexportar por cima é normal durante ajustes, o nome final já pode ser
   usado desde a primeira versão):
   ```
   node ~/projetos/viradeck/scripts/export-html.js <entrada.html> "Flayers/<nome>.png" <largura> <altura>
   ```
   (escala padrão 2x — boa pra impressão e tela retina; ajustar só se pedido)
6. **Sempre**, em toda resposta que gerar ou atualizar uma peça, termine a
   mensagem com essa linha exata (o chat do ViraDeck reconhece esse formato e
   mostra a imagem direto na tela — sem ela o Gabriel nunca vê o resultado):
   ```
   ![preview](Flayers/<nome>.png)
   ```

## Aprovação (regra já estabelecida do projeto)

Gabriel aprova toda peça visual antes de finalizar
(`memoria-claude/feedback_approve-visuals-stepwise.md`). Sempre:

- Gerar e mostrar o PNG exportado antes de considerar pronto.
- Uma peça de cada vez — não gerar um lote inteiro sem aprovação
  intermediária.
- Perguntar se quer ajuste antes de salvar a versão final em `Flayers/`.

## Onde salvar

Direto em `Flayers/`, com nome curto e descritivo em português, seguindo o
padrão já usado (ex: `Promoção Dia dos Pais.png`) — desde o primeiro
rascunho, não só na versão final. HTML de trabalho pode ficar num local
temporário; só o PNG precisa estar em `Flayers/`.
