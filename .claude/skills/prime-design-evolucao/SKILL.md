---
name: prime-design-evolucao
description: Direção criativa para elevar o visual do Prime Barbearia além do genérico — quando criar telas novas, redesenhar telas existentes, propor melhorias de interface, micro-interações, ou quando o usuário disser que algo está sem graça, genérico, ou pedir para deixar mais bonito. Use JUNTO com a skill prime-design, que define os tokens fixos — esta aqui diz COMO usar os tokens com intenção, não apenas quais são. Consulte antes de desenhar qualquer coisa nova.
---

# Prime Barbearia — Direção Criativa

A skill `prime-design` define **o que** usar (cores, fontes, raios). Esta define **como** usar para o resultado não parecer template.

## O risco a evitar

Fundo escuro + acento dourado + Cinzel é exatamente a combinação que qualquer IA produz quando ouve "barbearia premium". Os tokens estão certos — o perigo é a *execução* virar o mesmo card arredondado com borda dourada repetido vinte vezes. O Prime já tem uma base sólida (glass, animações de entrada do emblema, `prefers-reduced-motion` respeitado). O trabalho agora é dar personalidade, não adicionar mais brilho.

## De onde tirar as ideias: o mundo real da barbearia

Antes de desenhar qualquer coisa, procure a referência no ofício, não em dribbble genérico. Materiais e artefatos disponíveis:

- **A navalha e o fio**: linhas finíssimas (1px), cortes retos, o gesto do movimento único e preciso
- **O poste de barbeiro**: a listra helicoidal em movimento contínuo — vermelho/branco/azul não cabem na paleta, mas o *movimento em espiral lento* cabe (loading, transição, divisor animado)
- **O comprovante/comanda**: papel de recibo, monoespaçado, linha pontilhada de destaque, serrilha — perfeito para o financeiro e relatórios
- **O espelho e o corte**: simetria, reflexo, o "antes e depois"
- **Couro, mármore, latão**: texturas com granulação sutil, não gradiente liso
- **O agendamento como ritual**: horário marcado tem peso, não é um item de lista qualquer

## Princípios de execução

**1. Gaste a ousadia em um lugar só.** Escolha *um* elemento assinatura por tela e deixe todo o resto quieto e disciplinado. Se tudo brilha, nada brilha. Regra da Chanel: antes de entregar, tire um acessório.

**2. Estrutura carrega informação, não decoração.** Numeração, eyebrows, divisores e labels só entram se codificarem algo verdadeiro. Não use "01 / 02 / 03" a menos que exista sequência real. Uma linha dourada existe para separar duas coisas que precisam ser separadas.

**3. O dourado é acento, não banho.** Ele deve aparecer onde o olho precisa ir: a ação principal, o estado ativo, o valor que importa. Card genérico com borda dourada em volta é desperdício da cor mais forte da marca.

**4. Tipografia com escala real.** Cinzel funciona grande e com espaçamento entre letras aberto — em corpo pequeno vira ilegível. Jost 300 é leve por natureza: use tamanho e espaço em branco para criar hierarquia, não peso em negrito por toda parte.

**5. Movimento orquestrado bate movimento espalhado.** Uma sequência bem coreografada na entrada da tela vale mais que oito hovers com efeito. O projeto já tem `primeEmblemIn` e `primeWordIn` — esse é o padrão certo: um momento, bem feito. Sempre respeitar `prefers-reduced-motion` (já existe no código).

**6. Densidade combina com o uso.** Tela de barbeiro em dia cheio precisa de informação densa e toque rápido. Tela de cliente agendando pode respirar e ter momento. Não aplicar o mesmo ritmo visual nos dois.

## Ideias concretas por área (usar como ponto de partida, não copiar cego)

- **Agendamento**: horário selecionado como um gesto de confirmação com peso — não só um botão que muda de cor. O ato de marcar é o momento mais importante do app do cliente.
- **Financeiro / conciliação**: linguagem visual de comanda de papel — monoespaçado nos valores, alinhamento à direita, divisor pontilhado, totais destacados por posição e não por cor. Divergência de conciliação merece tratamento visual próprio (não é "erro" vermelho genérico, é "precisa de atenção").
- **Relatórios impressos**: já usam paleta clara. Tratar como papel de verdade: margem generosa, hierarquia por tamanho, dourado escuro só no cabeçalho.
- **Estados vazios**: nenhuma tela vazia deve dizer "nenhum registro encontrado". Diga o que fazer em seguida.
- **Loading**: já existe `skelShimmer`. Skeleton bem feito > spinner.

## Processo obrigatório antes de codar

1. **Nomeie o trabalho da tela em uma frase.** Qual é a única coisa que a pessoa precisa conseguir fazer ali?
2. **Escolha o elemento assinatura** dessa tela e justifique por que ele pertence ao mundo da barbearia.
3. **Faça a checagem do genérico**: se você chegaria nesse mesmo layout para "app de academia" ou "app de clínica" só trocando as cores, ele é genérico. Refaça essa parte e diga o que mudou.
4. Só então escreva o CSS, usando exclusivamente os tokens de `prime-design`.

## Escrita na interface

Palavra é material de design. Nomear pelo que a pessoa controla, nunca pelo que o sistema faz por dentro. Verbo ativo: "Confirmar agendamento", não "Enviar". O botão que diz "Finalizar atendimento" gera a mensagem "Atendimento finalizado" — mesmo vocabulário do começo ao fim. Erro explica o que houve e como resolver, sem pedir desculpa e sem ser vago.

## Piso de qualidade (sem anunciar)

Responsivo até o celular, foco de teclado visível, `prefers-reduced-motion` respeitado, contraste suficiente do prata sobre o verde-noite. Isso não é diferencial, é o mínimo.
