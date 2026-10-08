-- Nome/foto reais do WhatsApp (independe de cadastro no Prime) — cache preenchido só pelo
-- servidor de casa (único que fala com a WAHA), nunca pelo navegador.
create table public.whatsapp_contacts (
  chat_id text primary key,
  wa_name text,
  picture_url text,
  updated_at timestamptz not null default now()
);
alter table public.whatsapp_contacts enable row level security;
create policy whatsapp_contacts_staff_read on public.whatsapp_contacts for select
  using (exists (select 1 from barbers b where b.id = auth.uid() and b.role in ('vendas','admin')));
-- sem policy de insert/update pro navegador de propósito: só o servidor de casa (service_role).

-- Confirmação de entrega/leitura (✓/✓✓/✓✓azul) — preenchido pelo servidor de casa a partir do
-- evento message.ack da WAHA. Valores: SERVER (enviada), DEVICE (entregue), READ, PLAYED (áudio
-- ouvido), ERROR.
alter table public.whatsapp_messages add column ack text;

-- Apagar para todos. Nunca apagamos direto por UPDATE solto do navegador (poderia reescrever
-- qualquer coluna) — a equipe só pode marcar 'pedido' via RPC estreita (request_message_delete),
-- que confere dono/role e deixa só esse campo mexível; quem apaga de verdade na WAHA e grava
-- deleted_at é sempre o servidor de casa.
alter table public.whatsapp_messages
  add column delete_requested boolean not null default false,
  add column deleted_at timestamptz;

create or replace function public.request_message_delete(p_message_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from barbers b where b.id = auth.uid() and b.role in ('vendas','admin')) then
    raise exception 'sem permissão';
  end if;
  update whatsapp_messages
     set delete_requested = true
   where id = p_message_id
     and direction = 'outbound'      -- só mensagem nossa, igual o WhatsApp de verdade
     and status = 'sent'             -- só a que já foi enviada (tem wa_message_id real)
     and deleted_at is null;
end;
$$;
revoke all on function public.request_message_delete(bigint) from public;
grant execute on function public.request_message_delete(bigint) to authenticated;
