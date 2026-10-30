# Pagamento online com InfinitePay (Checkout Integrado)

Entra como mais um provedor da mesma estrutura do Pix (`appointment_payments`, reserva de 30 min, `registrar_pagamento_aprovado`).
Diferença: o InfinitePay não devolve QR Code; devolve um **link** do checkout deles (Pix ou cartão até 12x). O link vai em `ticket_url` e o site redireciona o cliente.

## Fluxo
1. O site chama `criar-pix` (`PIX_PROVEDOR=infinitepay`). Ele recalcula o valor, grava a cobrança e chama `POST https://api.infinitepay.io/invoices/public/checkout/links` (valor em centavos, `order_nsu` = id da cobrança, `webhook_url`, `redirect_url`).
2. O cliente paga no checkout do InfinitePay e volta para `INFINITEPAY_REDIRECT_URL` com `transaction_nsu`, `slug` e `order_nsu` na URL.
3. O InfinitePay chama `aviso-infinitepay` (webhook). O site, ao voltar, pode mandar o mesmo trio para a mesma função (conferência).
4. A função NUNCA confia no corpo: confere que o `order_nsu` é uma cobrança nossa, chama `payment_check` e só dá baixa se `paid === true` e `paid_amount >= valor cobrado` (lido do banco).
5. Idempotente: aviso repetido não muda nada. Consulta que falha devolve 400 (o InfinitePay reenvia).

## Configuração (Supabase > Edge Functions)
- Variáveis: `PIX_PROVEDOR=infinitepay`, `INFINITEPAY_HANDLE` (InfiniteTag, sem o `$`), `INFINITEPAY_REDIRECT_URL`.
- Segredo, só se a conta exigir: `INFINITEPAY_TOKEN` (enviado como `Authorization: Bearer`).
- Deploy: `supabase functions deploy criar-pix` e `supabase functions deploy aviso-infinitepay --no-verify-jwt`.

## Pontos em aberto (confirmar na conta real)
- Se a API exige token para a conta (o código já aceita).
- Taxa do Pix e do cartão: o `payment_check` não devolve a taxa; `fee`/`net` ficam em branco e o Financeiro usa a taxa cadastrada.
- O webhook não tem assinatura; por isso a conferência por `payment_check` é obrigatória.
- Vendas de maquininha não têm API pública: a conciliação delas é por importação do relatório (CSV/XLS) e OFX.

## Testes
```
node --experimental-strip-types --test supabase/functions/_shared/*.test.ts supabase/functions/criar-pix/handler.test.ts supabase/functions/aviso-infinitepay/handler.test.ts
```
