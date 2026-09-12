-- ST-3b.5 — amplia o CHECK de `sales.type` pra aceitar 'assinatura'.
--
-- Achado ao implementar `staff_crm_atualizar_plano` (ativar plano grava
-- venda de comissão, D-ST3b5-1): `sales_type_check` só aceita `NULL` ou
-- `'produto'` — **confirmado no baseline de produção** (28/08,
-- `prime/baseline-schema-2026-08-28`, não é hardening da ST-2.7; é schema
-- de produção original). O legado usa `type:'assinatura'` justamente pra
-- separar receita de assinatura de receita de serviço no dashboard
-- (`index.html` ~5468-5470: `receitaServicos` filtra
-- `type NOT IN ('produto','assinatura')`, `receitaAssinaturas` filtra
-- `type='assinatura'`).
--
-- ACHADO COLATERAL (bug já existente em produção, fora do escopo desta
-- fatia — só registrado): como o CHECK de produção nunca aceitou
-- 'assinatura', `baInsertSales` (index.html:4625-4629) sempre falha nesse
-- insert — e o erro é engolido (`console.error` + `return []`,
-- `baAssignPlan` não confere o retorno). Ou seja: **hoje, em produção,
-- ativar um plano pago NUNCA gerou a venda de comissão** — falha
-- silenciosa, sem qualquer aviso ao barbeiro. Não é corrigido aqui (é
-- schema/comportamento de produção, fora do escopo de uma fatia de CRM);
-- registrado para decisão futura do Gabriel.
--
-- Esta migration só amplia o CHECK NO LAB, pra que a RPC nova desta fatia
-- consiga gravar `type:'assinatura'` sem errar — não toca produção.
--
-- Rollback:
--   alter table public.sales drop constraint sales_type_check;
--   alter table public.sales add constraint sales_type_check
--     check (type is null or type = 'produto');
-- Impacto no legado: nenhum — só o lab; produção segue com o CHECK original.

alter table public.sales drop constraint sales_type_check;
alter table public.sales add constraint sales_type_check
  check (type is null or type in ('produto', 'assinatura'));
