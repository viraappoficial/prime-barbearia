---
name: prime-design
description: Tokens de design do Prime Barbearia — paleta de cores, tipografia, glassmorphism, raios e sombras, extraídos direto das variáveis CSS do index.html. Use sempre que for escrever ou revisar CSS no projeto, escolher uma cor, fonte, raio de borda ou efeito visual. Consulte ANTES de escrever qualquer `color:`, `background:` ou `border` — só usar os tokens daqui, nunca inventar hex novo. Use JUNTO com a skill prime-design-evolucao, que define a direção criativa de como aplicar esses tokens com intenção.
---

# Prime Barbearia — Sistema de Design (tokens)

Fonte da verdade: variáveis `:root` no `index.html`. Esta skill documenta o que existe hoje — se o CSS mudar, atualize aqui também (ver skill `prime-skills-manutencao`).

## Regra de ouro

**Sempre `var(--token)`, nunca hex solto.** Se a cor que você precisa não está na tabela abaixo, ela não existe no sistema — pare e pergunte antes de inventar um hex novo direto no CSS. Exceção: o tema de impressão (`--rp-*`, ver seção própria) e casos hardcoded documentados como pendência abaixo.

## Paleta principal (`:root`, linha ~127 do index.html)

| Token | Valor | Uso |
|---|---|---|
| `--verde-neon` | `#35C558` | Ação, marca, sucesso — cor de destaque "viva" (hover, CTA, glow) |
| `--verde-prime` | `#1E6B33` | Verde base de botão primário e fundo de destaque |
| `--verde-noite` | `#0B140D` | Fundo principal do app (quase preto esverdeado) |
| `--grafite` | `#141715` | Fundo de seção alternada (contraste sutil com verde-noite) |
| `--grafite-card` | `#1A1E1B` | Fundo sólido de card (fallback de quem não suporta glass) |
| `--prata` | `#EDEDE8` | Texto principal sobre fundo escuro |
| `--prata-dim` | `#9BA39C` | Texto secundário/legenda, menos contraste que `--prata` |
| `--dourado` | `#C6A75E` | Acento — valor que importa, estado ativo, ação principal (ver regra do dourado em `prime-design-evolucao`) |
| `--dourado-claro` | `#E8D5A4` | Variante mais clara do dourado — hover de elemento dourado, texto sobre fundo escuro que precisa de leitura fácil |
| `--dourado-dim` | `rgba(198,167,94,.35)` | Dourado translúcido — bordas e divisores discretos (`.gold-rule`, cards) |
| `--hair` | `rgba(237,237,232,.12)` | Hairline neutra — borda fina de tabelas, inputs e divisores do painel do barbeiro (`.cad-table`, `.add-input`, `.expense-row`, `.cap-row`) |
| `--erro` | `#E58A6B` | Estado de erro/indisponível (ex: produto esgotado) |
| `--alerta` | `#D9A441` | Estado de atenção (ex: divergência precisa de atenção, avisos no DRE) |
| `--violeta` | `#9B7EDE` | Estado auxiliar — hoje usado pra indicação/mimo, distinto do dourado de fidelidade |

## Tipografia

| Token | Valor | Uso |
|---|---|---|
| `--font-display` | `'Cinzel', serif` | Títulos (`h1,h2,h3`), números de destaque, marca — grande, com espaçamento de letra aberto. Ilegível em corpo pequeno (ver `prime-design-evolucao`) |
| `--font-body` | `'Jost', sans-serif` | Todo o resto — texto corrido, botões, labels. Peso padrão do body é 300 (leve) |

## Glassmorphism (`:root`, linha ~9673)

```css
--glass-card: rgba(24,28,25,.42);
--glass-blur: blur(20px) saturate(135%);
```

Aplicado com `background:var(--glass-card)` + `backdrop-filter:var(--glass-blur)` + sombra fixa `inset 0 1px 0 rgba(237,237,232,.08), 0 6px 24px rgba(0,0,0,.26)` — é a receita padrão dos cards "neutros" do app (`.ba-card`, `.meta-card`, `.stat-tile`, `.club-card`, `.svc`, `.review`, etc.). Cards de destaque com gradiente próprio e elementos pequenos (inputs, avatares, pontinhos) ficam **fora** dessa regra de propósito — não aplicar glass neles.

Existe fallback via `@supports not (backdrop-filter)`: nesses dispositivos o card vira fundo sólido `var(--grafite-card)`. Ao criar um card novo que deveria ter glass, lembre de incluir o seletor também nesse bloco `@supports`.

## Tema de impressão / papel (`#ba-report-print`, linha ~9620)

Relatórios, DRE exportado e o QR code impresso usam uma paleta **separada e clara**, porque são "papel de verdade" (ver `prime-design-evolucao`) — não usam a paleta escura principal:

| Token | Valor | Uso |
|---|---|---|
| `--rp-paper` | `#FBF9F3` | Fundo da página impressa |
| `--rp-card` | `#F3EFE2` | Fundo de bloco/estatística dentro do relatório |
| `--rp-ink` | `#20241D` | Texto principal no papel |
| `--rp-ink-dim` | `#6B6E63` | Texto secundário no papel |
| `--rp-dourado` | `#B08D3E` | Dourado escuro só no cabeçalho (regra explícita: dourado do papel é mais escuro que o dourado do app, pra funcionar em fundo claro) |
| `--rp-dourado-claro` | `#8C6F2E` | Subtítulo/eyebrow no papel |
| `--rp-hair` | `#DCD3B8` | Linha divisória fina no papel |

Esses tokens só existem escopados dentro de `#ba-report-print` — não usar `--rp-*` fora do contexto de impressão, e não usar a paleta escura principal dentro do relatório.

## Escala de raio (convenção, ainda não é token)

Não existe `--raio-*` como variável — os valores em pixel se repetem por convenção. Ao criar um elemento novo, seguir esta escala em vez de inventar um número:

- `3px`–`4px`: controles pequenos (botão de ícone, chip, badge)
- `6px`–`8px`: inputs, cards padrão, tabelas
- `10px`–`12px`: cards maiores, blocos de destaque, moldura de QR
- `99px`/`999px`: pill (badge arredondado) e círculo (avatar, botão redondo)

## Sombras comuns

- **Glow de ação primária**: `box-shadow:0 0 24px rgba(53,197,88,.25)`, hover `0 0 34px rgba(53,197,88,.5)` — usa a cor de `--verde-neon` em rgba porque `box-shadow` não aceita `var()` dentro de função de cor diretamente combinada; é a mesma cor do token, só repetida em rgba.
- **Glass**: ver seção Glassmorphism acima — sombra fixa combinada com o blur.
- **Pulso do CTA de navegação**: `@keyframes navPulse` alternando `box-shadow:0 0 16px rgba(53,197,88,.5)` — sempre com `@media(prefers-reduced-motion:reduce){animation:none}` ao lado.

## `backdrop-filter` fora do glass system

Além do `var(--glass-blur)`, o projeto usa blur pontual em headers/overlays fixos: `blur(2px)` na nav no topo da página, `blur(4px)` em modais e headers sticky dos apps, `blur(5px)`–`blur(6px)` em overlays cheios (unlock de conquista, tabbar do barbeiro). Regra prática: quanto mais o elemento cobre a tela, mais forte o blur.

## Histórico

`--hair` foi usada em dezenas de lugares por meses sem nunca ter sido declarada em nenhum `:root` — as bordas que dependiam dela ficavam silenciosamente inválidas (browser ignora a declaração inteira quando `var()` não resolve). Corrigido em 2026-08-06: token declarado com `rgba(237,237,232,.12)`, hairline neutra consistente com o resto da paleta escura.
