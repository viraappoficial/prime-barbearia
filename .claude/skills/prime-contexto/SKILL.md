---
name: prime-contexto
description: Contexto e decisões de arquitetura do projeto Prime Barbearia (sistema de agendamento/gestão para barbearia). Use sempre que o usuário mencionar "Prime", "Prime Barbearia", agendamento de barbearia, ou pedir para trabalhar em qualquer parte do sistema (agendamentos, pagamentos, chatbot, financeiro, deploy). Consulte esta skill ANTES de sugerir stack, arquitetura ou integrações novas — várias decisões já foram tomadas e não devem ser reabertas sem necessidade.
---

# Prime Barbearia — Contexto do Projeto

Sistema de gestão/agendamento para barbearia. Domínio: primebarbearia.app.br

## Stack e decisões já tomadas (não reabrir sem motivo forte)

- **Backend/dados**: Supabase
- **Hospedagem**: em migração de Git (hospedagem atual) para **Vercel**, por segurança
- **E-mails do sistema** (auth, confirmação de agendamento): devem sair do domínio próprio (primebarbearia.app.br), não do domínio padrão do Supabase
- **WhatsApp**: integração direta com **WhatsApp Cloud API (Meta)**, sem BSP/integrador pago — o time (Gabriel + Claude) desenvolve por conta própria
- **IA no produto**: usar **Claude Haiku** (barato) só para o chatbot de CRM/agendamento. Campanhas de marketing com IA foram tiradas do escopo (Haiku não dava conta bem dessa parte)
- **Financeiro**: ver skill `prime-financeiro` para o workflow de conciliação, relatórios e DRE

## Áreas do sistema (roadmap conhecido)

1. **Agendamento**: já existe; falta adicionar pagamento online (tipo Stripe) para cliente pagar antes do atendimento, e desconto aplicável pelo barbeiro no fechamento do carrinho
2. **Financeiro**: registrar forma de pagamento + NSU por atendimento, conciliação com extrato bancário, relatórios, contas a pagar, DRE (ver skill `prime-financeiro`)
3. **Chatbot**: CRM + confirmação de horário via WhatsApp/Instagram, rodando em Claude Haiku
4. **Marketing/visibilidade**: campanhas dentro do próprio SaaS (Canva, tráfego pago) — sem IA automatizando isso por enquanto
5. **Infra**: migração da hospedagem para
