-- Responder uma mensagem específica (igual o WhatsApp real): guarda o id da WAHA da mensagem
-- original (reply_to_wa_id, pro servidor de casa mandar como reply_to de verdade pra WAHA) e
-- uma prévia curta (reply_to_preview/reply_to_direction) só pra desenhar a citação na bolha
-- sem precisar buscar a mensagem original de novo. reply_to_wa_id fica nulo quando a mensagem
-- respondida ainda não tem id real da WAHA (ex: resposta nossa ainda 'pending') — nesse caso a
-- citação aparece na tela, só não vira link nativo quando enviar de verdade.
alter table public.whatsapp_messages
  add column reply_to_wa_id text,
  add column reply_to_preview text,
  add column reply_to_direction text check (reply_to_direction in ('inbound','outbound'));

-- Mídia enviada pela equipe (foto/câmera/print colado/áudio gravado). Escopo desta fatia: só
-- SAÍDA (o que a equipe manda) — mídia que o CLIENTE manda continua só como "mensagem com mídia"
-- sem anexo visível aqui (a WAHA baixa e hospeda ela do lado dela; re-hospedar o que o cliente
-- manda fica pra uma fatia futura, deliberadamente fora desta). O arquivo fica no Storage
-- (bucket próprio, público-leitura, nome aleatório — mesma lógica de product-images/barber-photos
-- já usada no app); media_url é o que o servidor de casa manda pra WAHA como RemoteFile.
alter table public.whatsapp_messages
  add column media_url text,
  add column media_mimetype text,
  add column media_kind text check (media_kind in ('image','audio','video','file'));
-- body continua NOT NULL (schema já existente) — mídia sem legenda grava body='' (string vazia,
-- não nula), simples e sem precisar relaxar a constraint.

insert into storage.buckets (id, name, public)
values ('whatsapp-media', 'whatsapp-media', true)
on conflict (id) do nothing;

create policy whatsapp_media_public_read on storage.objects for select
  using (bucket_id = 'whatsapp-media');
create policy whatsapp_media_staff_upload on storage.objects for insert to authenticated
  with check (
    bucket_id = 'whatsapp-media'
    and exists (select 1 from public.barbers b where b.id = auth.uid() and b.role in ('vendas','admin'))
  );
