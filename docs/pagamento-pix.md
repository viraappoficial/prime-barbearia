# Pagamento online com Pix (Mercado Pago)

Plano completo (escopo, passo a passo da conta, fluxo, banco, segurança, fases e testes): documento "Prime Barbearia — Pagamento online com Pix (Mercado Pago)" no Claude Docs (https://claude.ai/artifact/1P1GyXXPt5ghydZdfRDx8t).

## O que existe no repositório (Fase 2)

- `supabase/migrations/20261020020000_pagamentos_pix.sql`: `payment_rules`, `appointment_payments`, colunas novas em `appointments` e `sale_payments`, e as funções `payment_required_for`, `pix_payment_status`, `expirar_pagamentos_pix`, `registrar_pagamento_aprovado`, `marcar_pagamento_estornado`.
- `supabase/functions/criar-pix`: cria a cobrança Pix (valor recalculado no servidor, reserva de 30 min).
- `supabase/functions/aviso-mp`: webhook do Mercado Pago (confere a assinatura e consulta o pagamento antes de marcar como pago).
- `supabase/functions/_shared/pix-core.ts`: regras puras (valor, CPF, vencimento, assinatura, taxa, estado).

## Testes

```
node --experimental-strip-types --test supabase/functions/_shared/pix-core.test.ts supabase/functions/criar-pix/handler.test.ts supabase/functions/aviso-mp/handler.test.ts
```

## Segredos (Supabase > Edge Functions > Secrets; nunca no site nem no repositório)

`MP_ACCESS_TOKEN` e `MP_WEBHOOK_SECRET`.

## Deploy

```
supabase functions deploy criar-pix
supabase functions deploy aviso-mp --no-verify-jwt
```

URL do webhook para cadastrar no painel do Mercado Pago: `https://<projeto>.supabase.co/functions/v1/aviso-mp`.
