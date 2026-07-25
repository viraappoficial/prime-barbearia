# Memória do Claude — Prime Barbearia

Esta pasta é uma **cópia sincronizada** da memória que o Claude Code guarda sobre esse projeto (contexto entre conversas: decisões tomadas, planos em andamento, preferências do Gabriel).

O original vive fora do repositório, em `~/.claude/projects/.../memory/` — uma pasta interna do Claude Code, presa à máquina/caminho onde ele foi criado. Essa cópia aqui existe só pra ficar **acessível em qualquer computador** que clonar este repositório.

## Como usar em outra máquina
Ao abrir o Claude Code nesse projeto num PC novo, peça pra ele ler os arquivos desta pasta (`memoria-claude/*.md`) pra recuperar o contexto — decisões já tomadas, planos em andamento (conciliação financeira, contas a pagar), preferências de como trabalhar.

## Regra combinada (2026-07-25)
Sempre que a memória for atualizada nessa sessão, ela também é copiada pra cá e commitada/enviada pro GitHub — pra nunca ficar desatualizada em relação ao original.

## Arquivos
- `MEMORY.md` — índice de tudo, com um resumo de uma linha por memória
- `feedback_*.md` — preferências de como o Gabriel gosta que o trabalho seja feito
- `project_*.md` — contexto de projetos/planos em andamento
