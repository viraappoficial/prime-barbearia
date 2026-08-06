---
name: prime-skills-manutencao
description: Mantém as skills do projeto Prime Barbearia (prime-contexto, prime-financeiro, prime-design, prime-design-evolucao) sincronizadas com a realidade do código. Use SEMPRE que uma decisão de arquitetura mudar, uma etapa do roadmap for concluída, um token de design for alterado, uma integração nova entrar no projeto, ou quando o usuário disser "atualiza as skills", "isso mudou", "já terminei essa fase" ou apontar que uma skill está desatualizada. Use também no início de sessões longas para conferir se as skills ainda batem com o código.
---

# Manutenção das Skills do Prime

As skills do Prime só valem enquanto refletem a verdade. Skill desatualizada é pior que skill nenhuma: faz o Claude trabalhar com decisão velha e defender escolha que já foi abandonada.

## As quatro skills e o que cada uma guarda

| Skill | Guarda | Fonte da verdade no repo |
|---|---|---|
| `prime-contexto` | Stack, decisões de arquitetura, roadmap, integrações | `ROADMAP.md`, `package.json`/config de deploy, `.mcp.json` |
| `prime-financeiro` | Modelo de dados financeiro, fluxo de conciliação, caminho pro DRE | schema em `supabase/`, código dos lançamentos e relatórios |
| `prime-design` | Tokens: paleta, tipografia, raios, sombras | variáveis CSS no `index.html` |
| `prime-design-evolucao` | Direção criativa, princípios, processo anti-genérico | não tem fonte automática — muda só por decisão do usuário |

## Gatilhos de atualização

Atualize **na mesma sessão em que o fato acontecer**, sem esperar o usuário pedir:

- Uma etapa do roadmap foi concluída → tirar de "em andamento", registrar como feita em `prime-contexto`
- Uma decisão de stack mudou (banco, hospedagem, gateway de pagamento, modelo de IA) → substituir a linha antiga, **mantendo o histórico** no formato "X (antes era Y)"
- Uma variável CSS foi adicionada, removida ou teve o valor trocado → atualizar `prime-design`
- Um campo novo entrou no modelo financeiro (nova forma de pagamento, novo identificador) → atualizar `prime-financeiro`
- O usuário definiu um novo princípio visual ou rejeitou uma direção → registrar em `prime-design-evolucao`
- Uma pendência listada foi resolvida → remover da lista de pendências

## Como atualizar (sempre nesta ordem)

1. **Confira a fonte da verdade antes de escrever.** Nunca atualize uma skill baseado só no que o usuário falou de memória — leia o arquivo correspondente no repo e confirme. Se o que o usuário disse conflitar com o código, aponte a divergência em vez de escolher um lado sozinho.
2. **Edite cirurgicamente.** Troque a linha específica; não reescreva o SKILL.md inteiro. Reescrita completa perde nuance acumulada.
3. **Preserve histórico de decisão.** "Vercel (migração do GitHub Pages concluída)" é melhor que só "Vercel" — quem ler depois entende por que foi feito.
4. **Não infle.** Skill boa é curta. Se um bloco cresceu demais, condense ou mova para um arquivo de referência em vez de deixar o SKILL.md gigante.
5. **Commite** com mensagem descrevendo o que mudou, ex: `atualiza prime-contexto: migração Vercel concluída`.
6. **Avise o usuário em uma linha** o que foi atualizado e por quê. Sem pedir permissão para correções factuais óbvias; perguntar antes só quando a mudança for de opinião/direção.

## Auditoria periódica

Quando o usuário pedir uma revisão geral (ou no início de uma sessão longa de trabalho no Prime), rode esta checagem:

1. Extraia as variáveis CSS atuais do `index.html` e compare com a paleta em `prime-design` — reportar qualquer divergência
2. Leia o `ROADMAP.md` e compare com o roadmap listado em `prime-contexto` — o que já foi feito ainda está marcado como pendente?
3. Verifique se alguma integração citada nas skills foi abandonada, ou se entrou alguma nova que não está documentada
4. Liste as divergências encontradas para o usuário decidir, e aplique as correções factuais diretamente

## O que NÃO fazer

- Não criar skill nova para cada assunto pequeno — quatro skills bem mantidas valem mais que doze fragmentadas. Assunto novo, primeiro pergunte se cabe numa existente.
- Não apagar uma skill por conta própria. Só a pedido explícito do usuário.
- Não copiar credencial, chave de API, token do Supabase ou dado de cliente para dentro de uma skill — elas vão pro repositório e são lidas em toda sessão.
- Não registrar como decisão algo que foi só sugestão sua ainda não aprovada pelo usuário. Só entra na skill o que ele confirmou.
