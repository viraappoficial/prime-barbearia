-- Observação interna por conversa (Ficha da aba Zap) — guardada por chat_id (não por client_id)
-- porque muitos contatos que escrevem no WhatsApp ainda não têm cadastro no Prime; assim a
-- equipe consegue anotar algo (ex: "ligou perguntando sobre promoção") mesmo sem cliente vinculado.
create table public.whatsapp_contact_notes (
  chat_id text primary key,
  note text not null default '',
  updated_at timestamptz not null default now(),
  updated_by uuid references public.barbers(id)
);
alter table public.whatsapp_contact_notes enable row level security;

create policy whatsapp_contact_notes_staff_all on public.whatsapp_contact_notes for all
  using (exists (select 1 from barbers b where b.id = auth.uid() and b.role in ('vendas','admin')))
  with check (exists (select 1 from barbers b where b.id = auth.uid() and b.role in ('vendas','admin')));
