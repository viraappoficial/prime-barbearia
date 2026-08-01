---
name: feedback-never-touch-vira-supabase
description: "Regra crítica de segurança: nunca mexer no projeto Supabase do Vira (nem em outros projetos que não sejam o Prime Barbearia) a menos que Gabriel peça explicitamente."
metadata:
  node_type: memory
  type: feedback
  modified: 2026-08-01T00:00:00.000Z
---

**Regra crítica (2026-08-01):** o conector Supabase do Claude nesta conta fica ligado à conta pessoal do Gabriel, que hospeda o projeto **Vira** (`vira.app.oficial@gmail.com's Project`, id `vpygbkwhfpyhabutgxxl`) — um projeto separado, não relacionado ao Prime Barbearia. Pra contornar isso, Gabriel forneceu um Personal Access Token do Supabase da conta certa (organização `zfnbhkcxjyqmnliroudg`), usado via API direta (curl com `Authorization: Bearer <token>`), que enxerga dois projetos: **Prime Barbearia** (`yojvzwkvtedxqlohpuug`) e **SEHORBAS** (`ramswvctsypojgfjfbkf`).

**Regra:** NUNCA executar nenhuma ação (leitura, escrita, migração, consulta, o que for) no projeto do Vira (`vpygbkwhfpyhabutgxxl`) nem no SEHORBAS (`ramswvctsypojgfjfbkf`) usando esse token ou o conector MCP, a menos que Gabriel peça explicitamente e nomeie o projeto. Por padrão, toda ação Supabase nesta sessão do Prime Barbearia deve mirar exclusivamente `yojvzwkvtedxqlohpuug` (Prime Barbearia). Se em algum momento não tiver certeza de qual projeto uma ação vai afetar, perguntar antes de executar.
