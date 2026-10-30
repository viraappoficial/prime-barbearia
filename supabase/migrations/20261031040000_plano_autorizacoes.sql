-- Pedido do Léo ao admin para um cliente de plano cortar com outro barbeiro que não o do plano.
-- Rollback: drop table public.plano_autorizacoes;
create table if not exists public.plano_autorizacoes (
  id bigint generated always as identity primary key,
  assinatura_id bigint not null references public.assinaturas(id) on delete cascade,
  client_phone text not null,
  client_name text not null,
  destino text not null,
  barber_id uuid not null,
  pedido_barber_nome text not null,
  day date not null,
  time text not null,
  servicos text[] not null,
  status text not null default 'pendente' check (status in ('pendente', 'aprovada', 'recusada', 'expirada')),
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by text
);
create index if not exists plano_autorizacoes_pendentes on public.plano_autorizacoes (status, created_at);
alter table public.plano_autorizacoes enable row level security;
drop policy if exists plano_autorizacoes_admin_read on public.plano_autorizacoes;
create policy plano_autorizacoes_admin_read on public.plano_autorizacoes for select to authenticated
  using (exists (select 1 from public.barbers b where b.id = auth.uid() and b.role = 'admin'));
grant select on public.plano_autorizacoes to authenticated;
