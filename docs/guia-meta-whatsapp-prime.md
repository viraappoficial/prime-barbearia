# Guia: colocar a Prime na API oficial do WhatsApp (Cloud API da Meta)

Só Prime. Conta, app, número e token **separados** de qualquer outro projeto.
Tudo abaixo foi conferido na documentação da Meta (ou marcado **[conferir]** quando veio de fonte de terceiros ou não deu pra confirmar). Nomes de tela mudam: se algo estiver com outro nome, o caminho é o mesmo.

---

## Visão geral (o que vai existir no fim)

| Peça | O que é | Quem cria |
|---|---|---|
| Conta Meta pessoal | seu Facebook, que "dona" o app | você (já tem) |
| **Portfólio empresarial** (Meta Business) | a "empresa" Prime Barbearia na Meta | você |
| **App** (tipo Business, produto WhatsApp) | a ponte entre o nosso sistema e a Meta | você |
| **WABA** (conta do WhatsApp Business) | onde ficam números e modelos | criada junto com o app |
| **Número de teste** | número grátis da Meta, só pra testar | vem pronto |
| **Usuário de sistema + token permanente** | a "chave" que o bot usa pra enviar | você |
| **Webhook** | endereço que a Meta chama quando chega mensagem | eu escrevo, você faz o deploy |
| Número real da barbearia | entra só na Fase B, depois de tudo validado | você |

Regra: **o token nunca vai em chat, print ou git.** Fica só no servidor (variável de ambiente) e nos segredos da Supabase.

---

## FASE A — Tudo com o número de teste (sem risco pro número real)

### A1. Portfólio empresarial
1. Entre em business.facebook.com com o seu Facebook.
2. Crie o portfólio **"Prime Barbearia"** (nome, seu nome, e-mail).
3. Use um e-mail que você controla. Esse portfólio é o dono de tudo (e é nele que, depois, se faz a verificação do negócio).

### A2. Conta de desenvolvedor e app
1. Entre em developers.facebook.com e faça o registro de desenvolvedor (confirma e-mail/telefone).
2. **My Apps → Create App**.
3. Nome do app: `Prime WhatsApp`. E-mail de contato.
4. Caso de uso: **Connect with customers through WhatsApp**.
5. Escolha o portfólio **Prime Barbearia** e confirme em **Create app**.

### A3. Abrir o WhatsApp no app e pegar os IDs
1. No painel do app, menu lateral → **WhatsApp → API Setup** (ou "Start using the API").
2. Se pedir, selecione/crie a conta do WhatsApp Business (WABA). Crie uma nova chamada "Prime".
3. Anote (pode me mandar, **não são segredo**):
   - **WhatsApp Business Account ID** (WABA ID)
   - **Phone number ID** do número de teste (é diferente do telefone!)
4. Em **To**, cadastre os telefones que vão receber os testes (o seu, Nathan e Miguel). Cada um confirma por código no WhatsApp. **Quanto cada número de teste permite de destinatários: [conferir] na tela do API Setup** (a página de introdução não informa o limite).
5. Use **Generate access token** só pra um primeiro teste manual: ele **expira em horas**.

### A4. Token permanente (o que o bot vai usar)
1. business.facebook.com → **Configurações do negócio (Business Settings) → Usuários → Usuários do sistema (System users) → Adicionar**.
2. Nome `prime-bot`, função **Admin**.
3. **Atribuir ativos (Assign Assets)**: o app `Prime WhatsApp` com **Gerenciar app** e a conta WhatsApp "Prime" com **controle total**.
4. **Gerar token (Generate token)**, escolha o app e marque as permissões:
   - `whatsapp_business_messaging`
   - `whatsapp_business_management`
   - `business_management`
5. Copie o token **uma vez** e guarde num lugar seguro (gerenciador de senhas). **Não cole no chat.**

### A5. Webhook (eu preparo, você publica)
O código já está na branch `staff/meta-etapa1` (`supabase/functions/whatsapp-meta-webhook`). Passos, um de cada vez, que eu te guio:
1. Rodar o SQL `20261012000000_whatsapp_meta_etapa1.sql` na Supabase.
2. Definir os segredos: `META_APP_SECRET` (painel do app → Configurações do app → Básico → **Chave secreta do app**) e `META_WEBHOOK_VERIFY_TOKEN` (uma frase longa que **você inventa**).
3. Fazer o deploy da função **sem verificação de JWT** (a Meta não manda JWT).
4. No app da Meta: **WhatsApp → Configuration → Webhook → Edit**:
   - Callback URL: `https://<projeto>.supabase.co/functions/v1/whatsapp-meta-webhook`
   - Verify token: o mesmo inventado acima
   - Depois de verificar, **assinar o campo `messages`**.
5. Cadastrar o canal no banco (um INSERT em `whatsapp_channels` com o Phone number ID e o WABA ID — eu te mando pronto).
6. No servidor de casa: `META_WA_TOKEN=<token permanente>` no ambiente do bot e reiniciar.

### A6. Primeiro teste
1. Pelo WhatsApp do seu celular, mande "oi" pro **número de teste**. A mensagem deve aparecer no Zap.
2. Responda pelo painel (dentro das 24h é texto livre).
3. Teste "SAIR" e a mensagem em espera (fora das 24h).

### A7. Modelos (templates) de utilidade
Em **WhatsApp Manager → Modelos de mensagem → Criar modelo**, categoria **Utilidade** (não Marketing), idioma Português (Brasil):

| Nome | Variáveis | Botões |
|---|---|---|
| `confirmacao_agendamento` | nome, serviço, data/hora, barbeiro | — |
| `lembrete_vespera` | nome, data/hora, barbeiro | Confirmo / Remarcar / Cancelar |
| `aviso_barbeiro` | barbeiro, cliente, serviço, data/hora | Confirmo / Propor outro horário |
| `proposta_novo_horario` | nome, novo horário | Aceito / Outro horário / Cancelar |

- Textos curtos, sem promoção, sem link encurtado.
- **A aprovação é por número**: modelo aprovado no número de teste **não vale** no número real. Vai ser preciso recriar na Fase B (uns minutos até horas pra aprovar) **[conferir]**.
- A Meta pode reclassificar utilidade como marketing (e cobrar mais) se o texto parecer promoção.

---

## FASE B — Número real (só depois da Fase A validada e do painel pronto)

Decisão tomada: **opção B** — o número oficial da barbearia vai inteiro pra API e todo o atendimento passa pelo painel Zap. O celular **deixa de usar o WhatsApp desse número**.

### B1. Antes de mexer
1. **Backup das conversas** do celular (o histórico do app não vai pra API).
2. Avisar a equipe do dia/hora do corte.
3. Ter o painel pronto: indicador da janela de 24h, envio de modelo, respostas prontas.
4. Modelos aprovados **no número real** (ver A7).
5. **Verificação do negócio** no portfólio (Configurações do negócio → Central de segurança → Verificação). Ela pede dados da empresa (CNPJ, documentos) e sobe o limite de envios. Quanto exatamente: **[conferir]** no WhatsApp Manager, porque as regras de limite mudaram em 2025.
6. Nome de exibição ("Prime Barbearia") aprovado.

### B2. Passos técnicos pra trazer o número **[conferir tudo na doc da Meta na hora]**
1. No WhatsApp do celular, **desativar a verificação em duas etapas** (Configurações → Conta → Verificação em duas etapas), ou ter o PIN em mãos.
2. No **WhatsApp Manager → Ferramentas da conta → Números de telefone**, **adicionar** o número à WABA da Prime.
3. Confirmar a posse com o código de 6 dígitos (SMS ou ligação) — precisa estar com o chip na mão.
4. **Registrar** o número pela API (é uma chamada de API; não dá pelo painel). Existe limite de 10 tentativas por número em 72h.
5. Assinar o webhook do número, trocar o `phone_number_id` do canal no banco e testar com seu celular.
6. A partir daí o app do celular desse número para de funcionar. É esperado.

### B3. Depois do corte
- Qualidade do número (verde/amarelo/vermelho) no WhatsApp Manager: olhar todo dia nas primeiras semanas.
- Começar com poucos envios e subir aos poucos; sem rajada.
- Limite inicial de conversas iniciadas pela empresa em 24h: valores de terceiros indicam 250 sem verificação, subindo por faixas **[conferir]**.
- Custo: cobrança por mensagem de modelo (utilidade é bem mais barata que marketing). **Conferir a tabela de preços atual da Meta** antes de prever custo mensal.

### E a coexistência (opção C)?
Não vamos usar. Pelo que achei em fontes de terceiros, o Brasil estaria entre os países compatíveis, mas **não encontrei isso na documentação oficial**. Fica anotado só como plano B.

---

## O que eu preciso de você (e o que NUNCA mandar)

**Pode me mandar:** WABA ID, Phone number ID, o nome do app, prints das telas com erro (tapando token e chaves).
**Nunca mande:** token (temporário ou permanente), chave secreta do app, verify token, senha.

## Fontes
- Meta, Cloud API — Get Started: https://developers.facebook.com/docs/whatsapp/cloud-api/get-started
- Meta, registro de número: https://developers.facebook.com/documentation/business-messaging/whatsapp/business-phone-numbers/registration/
- Sobre coexistência/limites (terceiros, só como pista): Chakra, WATI, respond.io, Kommo.
