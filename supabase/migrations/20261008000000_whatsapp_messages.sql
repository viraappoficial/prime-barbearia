-- Chat do WhatsApp dentro do Prime (papel Vendas/admin) — V1 sem IA, bot de agendamento
-- automático (lista interativa) + esta tabela, que guarda o histórico e a fila de envio
-- numa linha de tempo só, pra virar um chat de verdade na tela.
--
-- Arquitetura (decidida em 08/10/2026): a WAHA roda isolada no servidor de casa do Gabriel
-- (não precisa de Railway nem de servidor próprio do Prime), mas NUNCA é alcançada de fora
-- pra enviar — o servidor de casa é sempre quem INICIA a conexão com o Supabase (nunca o
-- contrário), então não precisa expor nada publicamente nem mexer no Cloudflare Tunnel que
-- já serve outros serviços em produção:
--   - mensagem chega -> o servidor de casa grava aqui (direction='inbound', status='received')
--   - Vendas manda mensagem -> o navegador grava aqui (direction='outbound', status='pending')
--   - o servidor de casa confere esta tabela a cada poucos segundos, manda de verdade pela
--     WAHA e atualiza o status ('sent'/'failed') — só ele, via service_role, nunca o cliente.
create table public.whatsapp_messages (
  id bigint generated always as identity primary key,
  chat_id text not null,
  contact_phone text,
  direction text not null check (direction in ('inbound','outbound')),
  body text not null,
  -- id da WAHA pra mensagem (inbound: dedup de retry do webhook; outbound: preenchido só
  -- depois de enviar de verdade). Único só quando não nulo (não bloqueia duas pendentes).
  wa_message_id text,
  status text not null default 'received' check (status in ('received','pending','sent','failed')),
  error text,
  created_by uuid references public.barbers(id),
  created_at timestamptz not null default now(),
  sent_at timestamptz
);
create unique index whatsapp_messages_wa_message_id_key on public.whatsapp_messages (wa_message_id) where wa_message_id is not null;
create index whatsapp_messages_chat_id_idx on public.whatsapp_messages (chat_id, created_at);
-- fila que o servidor de casa consulta a cada poucos segundos
create index whatsapp_messages_pending_idx on public.whatsapp_messages (created_at) where status = 'pending';

alter table public.whatsapp_messages enable row level security;

-- leitura: só Vendas/admin (é dado de atendimento ao cliente, não é público nem do cliente final)
create policy whatsapp_messages_staff_read on public.whatsapp_messages for select
  using (exists (select 1 from barbers b where b.id = auth.uid() and b.role in ('vendas','admin')));

-- escrita pelo navegador: só cria mensagem de SAÍDA, sempre 'pending', sempre com o próprio
-- usuário como autor — nunca grava 'sent'/'failed' nem mensagem de entrada pelo app (isso é
-- só o servidor de casa, via service_role, que ignora RLS).
create policy whatsapp_messages_staff_insert_outbound on public.whatsapp_messages for insert
  with check (
    exists (select 1 from barbers b where b.id = auth.uid() and b.role in ('vendas','admin'))
    and direction = 'outbound' and status = 'pending' and created_by = auth.uid()
  );

-- sem policy de update/delete pro cliente comum de propósito: só o servidor de casa (service_role,
-- que ignora RLS) marca como enviada/falha — mesma decisão já usada em sales/appointments (Fase B/C).
