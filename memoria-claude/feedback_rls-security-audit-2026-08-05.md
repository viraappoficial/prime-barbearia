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

## Itens de menor gravidade — todos revisados em 2026-08-05

- **`notifications`** — CORRIGIDO. Antes: qualquer conta autenticada inseria notificação com conteúdo livre pra qualquer destinatário. Agora: staff (existe em `barbers`) continua livre; cliente só pode notificar a si mesmo (`for_role='client' AND recipient_client_id=auth.uid()`) ou notificar um barbeiro com um dos tipos legítimos que o app realmente usa client→barbeiro (`novo`/`cancelado`/`avaliacao`, exigindo que o `appt_id` seja de um agendamento de fato dele; ou `brinde`/`plano-solicitado`, que por natureza não têm agendamento associado — cliente escolhe qualquer barbeiro pra pedir um plano, então não dá pra exigir vínculo prévio aí sem quebrar o fluxo de assinatura de primeira viagem).
- **`referrals`** — CORRIGIDO. Antes: insert sem validar nada. Agora: só aceita se `referred_client_id = auth.uid()` (o cadastro só pode ser feito pela própria pessoa indicada, na hora do signup, como já é o único uso real do client-side) e `referrer_client_id ≠ referred_client_id` (bloqueia auto-indicação), ou staff (uso administrativo de vincular indicação manualmente).
- **`achievements`** — decisão: NÃO mexer. Todas as 6 conquistas do catálogo (`ACH_CATALOG`) são puramente cosméticas (badge no perfil) — não destravam brinde, desconto ou qualquer coisa de valor (brinde de fidelidade usa contagem de corte real via `loyalty_gifts`/`crm_clients`, tabela separada e corretamente protegida). Pior caso de abuso: cliente força a própria conquista falsa aparecer no PRÓPRIO perfil — não afeta ninguém além dele mesmo, não vale a complexidade de validar cada condição de desbloqueio no servidor.
