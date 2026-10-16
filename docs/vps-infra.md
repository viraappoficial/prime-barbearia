# VPS da Prime — o que roda, em qual porta e como mexer

> Anotações da montagem (14/10/2026). **Aqui não tem senha nem chave.** Segredos ficam só na VPS (arquivos `stack.env`) e em um gerenciador de senhas.

## Máquina
- Ubuntu, 3,8 GB de RAM, **swap de 2 GB** (arquivo `/swapfile`), disco de 49 GB (uns 15% usados).
- IP público: **76.13.229.246**.
- Firewall `ufw` ligado: entra só **22 (SSH), 80 e 443**. O Docker passa por cima do `ufw`, então porta publicada pelo Docker se fecha na stack (`127.0.0.1:porta:porta`).
- `fail2ban` ativo (bloqueia quem erra a senha do SSH várias vezes).
- Falta aplicar o **reinício** da VPS (atualização de segurança pendente).

## Domínio e DNS (Registro.br, modo avançado)
Domínio: `primebarbearia.app.br`

| Nome | Tipo | Aponta pra | Pra quê |
|---|---|---|---|
| `primebarbearia.app.br` | A | 216.198.79.1 (Vercel) | site |
| `www`, `staff` | CNAME | Vercel | site e painel da equipe |
| `painel` | A | 76.13.229.246 (VPS) | Evolution Go |
| `n8n` | A | 76.13.229.246 (VPS) | n8n |

Não mexer nas 3 primeiras linhas (site).

## O que roda e em qual porta
| Serviço (contêiner) | Porta | Quem enxerga | Endereço |
|---|---|---|---|
| **Caddy** (`caddy-caddy-1`, pasta `/opt/caddy`) | 80 e 443 | internet | faz o HTTPS e o certificado sozinho |
| **Evolution Go** (`evolutiongo-evolution-go-1`, imagem `evoapicloud/evolution-go:0.7.2`) | 4000 | **só a VPS** (`127.0.0.1`) | https://painel.primebarbearia.app.br/manager/instances |
| Postgres do Evolution (`evolutiongo-postgres-1`) | 5432 | só rede interna do Docker | — |
| **n8n** (`n8n-n8n-1`, versão 2.43.5) | 5678 | **só a VPS** (`127.0.0.1`) | https://n8n.primebarbearia.app.br |
| Postgres do n8n (`n8n-n8n-db-1`, Postgres 16) | 5432 | só rede interna | — |
| **Portainer** (`portainer`) | 9443 e 8000 | **aberta na internet** (decisão: deixar assim por enquanto) | https://76.13.229.246:9443 |
| `postgres_db` e `pgadmin_web` (stack 1) | 5432 e 8080 | **PARADOS** (`restart=no`) | — |

Roteamento do Caddy (`/opt/caddy/Caddyfile`): `painel.…` → `127.0.0.1:4000` e `n8n.…` → `127.0.0.1:5678`.

## Onde ficam os arquivos das stacks (criadas pelo Portainer)
Pasta base: `/var/lib/docker/volumes/portainer_data/_data/compose/`
- `1` = `postgres_db` + `pgadmin_web` (parados; banco vazio de 46 MB, sem uso).
- `2` = **Evolution Go** — projeto `evolutiongo`, variáveis em `stack.env`. Cópia de segurança: `docker-compose.yml.bak`. A linha 52 já foi trocada pra `127.0.0.1:4000:4000`.
- `3` = **n8n** — projeto `n8n`, variáveis em `stack.env`. Cópia de segurança: `docker-compose.yml.bak`. Já ajustado: porta `127.0.0.1:5678`, `N8N_HOST`, `N8N_PROTOCOL=https`, `N8N_EDITOR_BASE_URL`, `N8N_WEBHOOK_URL`, `WEBHOOK_URL` e `N8N_SECURE_COOKIE=true`.

Pra reaplicar o n8n: `cd .../compose/3 && docker compose -p n8n --env-file stack.env up -d`.

## Comandos úteis
```bash
# ver tudo e as portas
docker ps --format 'table {{.Names}}\t{{.Ports}}'
ss -tulpn

# reaplicar a stack do Evolution depois de editar o arquivo
cd /var/lib/docker/volumes/portainer_data/_data/compose/2
docker compose -p evolutiongo --env-file stack.env up -d

# logs
docker logs --tail 50 evolutiongo-evolution-go-1
docker logs --tail 50 n8n-n8n-1
docker logs --tail 50 caddy-caddy-1

# Caddy: depois de editar /opt/caddy/Caddyfile
cd /opt/caddy && docker compose restart

# religar o banco/pgAdmin parados (se um dia precisar)
docker start postgres_db pgadmin_web

# resetar a senha do n8n (mantém fluxos e credenciais)
docker exec -u node -it n8n-n8n-1 n8n user-management:reset && docker restart n8n-n8n-1

# resetar a senha do Portainer (mostra senha nova só na tela)
docker stop portainer
docker run --rm -v portainer_data:/data portainer/helper-reset-password
docker start portainer
```

## Estado dos segredos (sem os valores)
| Segredo | Estado |
|---|---|
| Senha do Portainer (`admin`) | resetada; a temporária apareceu no chat → **trocar em My account → Change password** |
| Dono do n8n | resetado e recriado em 14/10 |
| `GLOBAL_API_KEY` do Evolution | apareceu em prints e conversa; **decisão: não trocar por enquanto** (rever antes de ligar o chip de verdade) |
| Senhas dos bancos (Evolution, n8n) | apareceram em prints; trocar no fim |
| Senha de `root` (SSH) | apareceu em print; trocar e passar pra chave SSH |

## Servidor do bot (VPS) — Evolution como canal principal
- Pasta: `/opt/assistente/proto-ia` (compose + `.env` com os segredos, `chmod 600`). Contêiner `proto-ia-assistente-1`, porta `127.0.0.1:4030`, Caddy `bot.primebarbearia.app.br` -> `127.0.0.1:4030`.
- Webhook do Evolution (instância `prime`, evento MESSAGE): `https://bot.primebarbearia.app.br/webhook/evolution/<WEBHOOK_SEGREDO>`.
- O WAHA e o bot de casa foram aposentados. Migration: `20261016000000_whatsapp_channel_evolution.sql`.
- Atualizar: no pop-os `git pull` + `rsync -av --exclude node_modules --exclude .git <repo>/ root@76.13.229.246:/opt/assistente/`; na VPS `cd /opt/assistente/proto-ia && docker compose up -d --build`.

## O que ainda falta
1. ~~Fechar a porta 5678 do n8n~~ (feito em 14/10).
2. Decidir o **chip** (separado do número principal) e conectar na instância `prime` do Evolution (QR Code).
3. Colocar o **bot do WhatsApp** na VPS (Docker) e criar o canal Evolution no código; depois endereço `bot.primebarbearia.app.br`.
4. Trocar senhas/chaves dos prints; entrar por **chave SSH**.
5. **Reiniciar a VPS** e conferir que tudo sobe sozinho.
6. Backups (dados do n8n e do Evolution).
7. Confirmar a **licença** do Evolution Go (algumas versões pedem ativação).
