-- Pagamento do plano pelo site (checkout InfinitePay). A cobrança é nossa (id = order_nsu); o aviso do InfinitePay só
-- vale depois do payment_check (feito na Edge Function). Só a Edge Function (service_role) mexe aqui; o cliente não lê nem grava.
create table if not exists public.assinatura_cobrancas (
  id uuid primary key default gen_random_uuid(),
  assinatura_id bigint not null references public.assinaturas(id) on delete cascade,
  amount numeric(10,2) not null check (amount > 0),
  status text not null default 'pendente' check (status in ('pendente', 'aprovado', 'cancelado', 'precisa_estorno')),
  provider_payment_id text,
  ticket_url text,
  capture_method text,
  installments integer,
  paid_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists assinatura_cobrancas_assinatura_idx on public.assinatura_cobrancas (assinatura_id);
alter table public.assinatura_cobrancas enable row level security;
-- sem policies: ninguém (anon/authenticated) lê ou grava; service_role ignora RLS
revoke all on public.assinatura_cobrancas from anon, authenticated;

-- Baixa do pagamento: marca aprovado e ativa a assinatura (a mensalidade vira venda do barbeiro escolhido, como no balcão).
-- Devolve 'ok' | 'ja_aprovado' | 'precisa_estorno' (pagou, mas a assinatura já não pode ser ativada: devolver à mão).
create or replace function public.registrar_pagamento_plano(p_id uuid, p_provider_id text, p_paid_at timestamptz)
returns text language plpgsql security definer set search_path = public as $$
declare c public.assinatura_cobrancas%rowtype;
begin
  if coalesce(auth.role(), 'service_role') <> 'service_role' then raise exception 'sem permissão'; end if;
  select * into c from public.assinatura_cobrancas where id = p_id for update;
  if not found then raise exception 'cobrança não encontrada'; end if;
  if c.status = 'aprovado' then return 'ja_aprovado'; end if;
  if c.status = 'precisa_estorno' then return 'precisa_estorno'; end if;
  begin
    perform public.ativar_assinatura(c.assinatura_id, null);
  exception when others then
    update public.assinatura_cobrancas set status = 'precisa_estorno', provider_payment_id = p_provider_id, paid_at = p_paid_at where id = c.id;
    return 'precisa_estorno';
  end;
  update public.assinatura_cobrancas set status = 'aprovado', provider_payment_id = p_provider_id, paid_at = p_paid_at where id = c.id;
  return 'ok';
end $$;
revoke all on function public.registrar_pagamento_plano(uuid, text, timestamptz) from public, anon, authenticated;
