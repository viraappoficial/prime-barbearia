-- ST-6 (prime-next) — RPC pra o staff responder a avaliação pública que um
-- cliente deixou num atendimento concluído (`rating`/`rating_comment`),
-- gravando em `barber_reply` e notificando o cliente. Porta
-- `baSaveReply`/`primeAddNotif` do legado (index.html).
--
-- Escrita direta em `appointments` é banida no código de app do prime-next
-- (eslint `no-restricted-syntax`) — precisa de RPC mesmo já existindo RLS +
-- a trigger `_appointments_guard_update` permitindo a coluna `barber_reply`
-- pro staff (barbeiro na própria linha; admin em qualquer uma).
--
-- Regras (iguais ao legado):
--   • só em atendimento que TEM avaliação (`rating is not null`);
--   • barbeiro só responde a própria avaliação; admin responde qualquer uma
--     da equipe (mesmo escopo de `baRenderReviews`: admin vê/relaciona-se
--     com todas); `vendas` nunca chega nem na aba (bloqueado na UI) — negado
--     aqui também, defesa em profundidade;
--   • texto vazio (só espaços) remove a resposta (`nullif(trim(...), '')`),
--     igual ao `text || null` do legado;
--   • notifica o cliente só quando há texto novo E o atendimento tem conta
--     vinculada (`client_id`) — igual a `if(ap && ap.clientId && text)`.
create or replace function public.staff_responder_avaliacao(p_appt_id bigint, p_reply text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_role  text := public.barber_role();
  v_appt  public.appointments%rowtype;
  v_reply text;
begin
  if v_role is null or v_role = 'vendas' then
    raise exception 'FORBIDDEN' using errcode = 'P0001';
  end if;

  if p_appt_id is null then
    raise exception 'BAD_INPUT' using errcode = 'P0001';
  end if;

  select * into v_appt from public.appointments where id = p_appt_id;
  if not found or v_appt.rating is null then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;

  if v_role = 'barbeiro' and v_appt.barber_id <> v_uid then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;

  v_reply := nullif(trim(both from coalesce(p_reply, '')), '');
  if v_reply is not null and length(v_reply) > 500 then
    v_reply := left(v_reply, 500);
  end if;

  update public.appointments set barber_reply = v_reply where id = p_appt_id;

  if v_reply is not null and v_appt.client_id is not null then
    insert into public.notifications (for_role, recipient_client_id, type, appt_id, text)
    values (
      'client', v_appt.client_id, 'avaliacao', p_appt_id,
      coalesce((select name from public.barbers where id = v_appt.barber_id), 'O barbeiro')
        || ' respondeu sua avaliação: "'
        || (case when length(v_reply) > 60 then left(v_reply, 60) || '…' else v_reply end)
        || '"'
    );
  end if;

  return jsonb_build_object('appt_id', p_appt_id, 'reply', v_reply);
end;
$$;

grant execute on function public.staff_responder_avaliacao(bigint, text) to authenticated;
