# Referência: o que o painel Zap precisa ter (anotado de um omnichannel próprio em produção)

Fonte: relato de outro sistema próprio, já em produção (atende por painel web e WhatsApp oficial), repassado pelo Gabriel.
É **só referência de ideias**: nada de números, contas ou código daquele projeto entra na Prime.
Os itens abaixo são o que foi relatado, não algo que eu tenha verificado.

## 1) Quem está atendendo (posse da conversa)
- Cada conversa tem uma posse: um atendente ou "sem dono" (sala de espera). Quem não é o dono não responde.
- Login é por FILA, não global: o atendente só recebe conversa da fila em que está logado.
- Distribuição por "menos atendimentos abertos" entre quem está logado na fila. Sem ninguém logado, a conversa fica em ESPERA, visível, e não atribuída a quem não vai responder (decisão deliberada: um cliente já ficou mais de 2h invisível num sistema antigo).
- Dá pra assumir da sala de espera, transferir e encerrar com motivo. A transferência exclui quem deixou o cliente esperando.
- Quem fica um tempo configurável sem responder ninguém com cliente esperando é desconectado da fila.
- Nota interna é recado da equipe: nunca vai ao cliente (a tela impede E o servidor barra) e não conta como primeira resposta.
- Tempo real por SSE. O EventSource do navegador não manda cabeçalho Authorization; em vez de pôr o JWT na URL, usa um ticket de uso único válido por 30 s, consumido na primeira conexão (o cliente refaz o ciclo com recuo exponencial).

## 2) Janela de 24 horas no painel
- A janela é calculada por NÚMERO + contato: horas desde a última mensagem RECEBIDA do cliente naquele número (a casa tem vários números oficiais).
- Antes de deixar o atendente enviar, o servidor responde: pode ou não pode, quantas horas desde a última entrada, e se exige modelo.
- Janela aberta: caixa de texto livre.
- Janela fechada: a tela troca a caixa de texto por um seletor de MODELOS APROVADOS DAQUELE NÚMERO (modelo é por número; mostrar modelo de outro número dava recusa da Meta e o atendente só via "HTTP 502").
- Fora da janela e sem modelo aprovado: bloqueia com explicação clara, em vez de aceitar e falhar calado.
- Respeita opt-out: contato pode ter pedido para não receber marketing, ou para não receber avisos de utilidade (campos separados); a tela avisa.

## 3) Status e erro de cada mensagem
- Cada mensagem de saída guarda o status (enviado, entregue, lido) vindo dos eventos de status do webhook, e o erro quando falha.
- LIÇÃO: o erro ficava só no banco e a tela não mostrava; um problema (código de acesso que ninguém recebia) só foi descoberto consultando o banco. Hoje o motivo aparece explicado: número sem WhatsApp, fora da janela, bloqueio.
- A entrada deduplica pelo id externo da mensagem (o provedor reenvia).

## 4) Histórico e contato
- Contato unificado entre canais, com ponte para o cadastro de clientes e o opt-out guardado nele.
- A conversa de HOJE sempre vem inteira; o que passou disso vem por janela de histórico, com "carregar mais".
- Linha do tempo de eventos por conversa: quem atribuiu, transferiu, encerrou.
- Tempos de atendimento como colunas (aberto em, atribuído em, primeira resposta em, encerrado em), pra responder "esse cliente recebeu resposta?" sem varrer mensagens.

## 5) Para a migração
- Guardar a posse da conversa e a fila por login desde o começo (evita dois barbeiros respondendo o mesmo cliente).
- O servidor, e não só a tela, deve barrar o envio fora da janela e a nota interna.
- Mostrar sempre o motivo do erro ao atendente, nunca só "falhou".

---

## Como isso se compara com a Prime hoje (minha leitura do código, a confirmar)

| Ponto | Prime hoje | Situação |
|---|---|---|
| Posse da conversa | `assumed_by`/`assumed_at` em `whatsapp_contacts`; faixa "Atendimento humano: Nome"; `assume_whatsapp_chat` / `release_whatsapp_chat` | Existe, sem fila por login e sem transferência |
| Sem dono visível | `handoff_requested_at` + escalonamento em 5 e 10 min | Existe |
| Janela de 24h | Etapa 1: decide na hora de enviar (bot), mensagem fica `held` com motivo visível no Zap | Feito no bot; o painel ainda deixa digitar texto livre com janela fechada |
| Seletor de modelos aprovados no painel | — | Falta |
| Bloqueio no servidor (não só na tela) | Bot já segura fora da janela (`held`) | Parcial: falta barrar no momento da inserção |
| Status por mensagem | `ack` (✓ ✓✓) + `error`/`error_code`; Zap mostra o motivo | Existe |
| Dedup por id externo | `provider_msg_id` único (Meta) e `wa_message_id` (WAHA) | Existe |
| Opt-out | `whatsapp_optin.opted_out_at` (SAIR/PARAR), bot respeita | Existe, sem separar marketing x utilidade e sem aviso na tela |
| Nota interna | — | Não existe |
| Histórico | `select * ... limit(200)` por conversa | Sem "carregar mais" |
| Tempos de atendimento (colunas) | — | Não existe |
| Tempo real | Realtime do Supabase | Existe |

Ideias que mais valem pra Prime (pequenas e de alto retorno):
1. Painel: indicador da janela + trocar a caixa de texto por seletor de modelos quando fechada.
2. Servidor barrar envio fora da janela já na inserção (hoje só o bot segura depois).
3. Aviso de opt-out na tela do chat.
4. Nota interna.
