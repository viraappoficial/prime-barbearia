---
name: feedback-rls-security-audit-2026-08-05
description: "Auditoria de segurança das políticas RLS do Supabase (Prime Barbearia) feita em 2026-08-05 depois que o Gabriel viu comentários num Reels dizendo que stack Claude+Supabase costuma vazar dado. Achou 3 furos reais."
metadata:
  node_type: memory
  type: feedback
  modified: 2026-08-05T00:00:00.000Z
---

**Gatilho:** Gabriel viu um Reels sobre stack "vibe coding" (Claude, Supabase, Vercel etc.) com comentários alertando que esse tipo de app costuma ser fácil de vazar dado, e pediu pra verificar se a Prime tinha esses problemas. Tinha — 3 reais, todos corrigidos no mesmo dia.

**Por que isso acontece nesse tipo de stack:** o app conecta direto no Supabase pelo navegador usando uma chave pública (`anon key`/`publishable key`) que qualquer um vê no código-fonte da página. A segurança inteira depende das regras de RLS (row-level security) no banco — se uma regra ficar aberta demais, dá pra puxar dado direto da API sem "hackear" nada, só usando a própria chave do jeito errado.

## Os 3 furos encontrados e corrigidos

1. **`barbers` lia tudo pra qualquer visitante, sem login** — a policy de SELECT era `true` pra `public` (anon incluso), e o próprio app carregava essa tabela pra visitante anônimo montar a lista de barbeiros no agendamento. Vazava e-mail, `commission_pct` e `monthly_goal` de todo mundo. Corrigido: criada view `barbers_public` (só id/name/role/is_barber/hours/bio/experience/specialties/fun_fact/instagram_handle/photo_url — sem e-mail/comissão/meta), tabela base travada pra só leitura autenticada e depois só staff (ver item 3).

2. **`products` — custo de compra exposto pra qualquer conta logada, inclusive cliente comum** — a policy de SELECT (`products_authenticated_read`/`products_select_all`, ambas redundantes) liberava a tabela inteira (incluindo `cost`) pra qualquer `authenticated`, não só staff. A vitrine pública já usava corretamente uma view `products_public` (sem custo) — só a tabela base é que estava aberta demais pra quem soubesse consultar direto. Corrigido: SELECT na tabela base agora exige `exists (select 1 from barbers where id = auth.uid())` (só quem é staff).

3. **[MAIS GRAVE] Auto-promoção a admin via convite quebrado** — a policy `barbers_self_insert_via_invite` só checava "existe algum convite não usado no sistema inteiro", não que o código informado batesse com um convite de verdade. Como sempre sobra convite pendente (fluxo normal — testado com 2 pendentes no momento do achado), **qualquer conta autenticada podia se auto-inserir na tabela `barbers` com `role:'admin'` via API direta**, sem saber nenhum código, virando admin completo do sistema (acesso a tudo: financeiro, comissões, cancelar agendamento, etc). O fluxo real do app nunca usava essa policy — vai por `complete_barber_invite` (RPC `SECURITY DEFINER` que valida o código certo antes de inserir). Corrigido: policy removida (a RPC continua funcionando normal, roda com privilégio elevado independente de RLS de tabela).

## Metodologia usada (repetir se adicionar tabela nova com leitura pública)
1. `select tablename, rowsecurity from pg_tables where schemaname='public'` — confirmar RLS ligado em toda tabela.
2. `select tablename, policyname, cmd, roles, qual, with_check from pg_policies` — puxar tudo, filtrar por `qual='true'` ou `with_check='true'` ou `roles` incluindo `anon`/`public` sem condição real.
3. Pra cada policy suspeita: testar de verdade com a chave pública via curl direto na REST API (`https://<project>.supabase.co/rest/v1/<tabela>?select=*`) simulando um visitante anônimo — não confiar só na leitura da definição SQL.
4. Conferir se as colunas expostas fazem sentido pro caso de uso público (ex: `hours` faz sentido pro agendamento público; `commission_pct`/`cost`/`email` não fazem).
5. Rastrear funções RPC `SECURITY DEFINER` (`pg_proc` com `prosecdef=true`) — elas bypassam RLS de propósito, então uma tabela "trancada" ainda pode ter uma porta legítima por RPC; e o inverso também importa (uma policy de tabela solta pode ser uma porta dos fundos que nem o app usa mais, como foi o caso do convite).

## Itens de menor gravidade encontrados, NÃO corrigidos ainda (baixo risco, sem vazamento de dado)
- `notifications`: qualquer conta autenticada insere notificação com conteúdo livre pra qualquer destinatário (spam/spoofing interno, não lê dado de ninguém). Corrigir direito exige olhar os ~10 tipos de notificação um a um (alguns não referenciam `appt_id`, ex: conquista/brinde/plano-solicitado).
- `referrals`: insert sem validar se o referrer/referred faz sentido — risco de fraude no programa de indicação, não vazamento.
- `achievements`: cliente pode inserir uma conquista falsa pra si mesmo (`client_id=auth.uid()` é a única checagem) — integridade de gamificação, não vazamento.

Revisitar esses 3 se algum dia formalizarmos o programa de indicação ou notarmos abuso de verdade — não é urgente.
