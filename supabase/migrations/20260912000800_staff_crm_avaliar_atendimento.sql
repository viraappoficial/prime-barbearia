-- ST-3c.3 — avaliação privada do cliente pelo barbeiro (`client_rating` /
-- `client_rating_comment` em `appointments`).
--
-- Correção de entendimento (ver docs/investigacoes/15-staff-st3c-
-- relacionamento.md §0): `rating`/`rating_comment`/`rating_by` é o CLIENTE
-- avaliando o corte/barbeiro (público, landing). `client_rating`/
-- `client_rating_comment` é o BARBEIRO avaliando o CLIENTE (privado) — é
-- essa dupla que entra na ficha do CRM.
--
-- Decisão de design (D-ST3c-3-implícita, escolhida no chat): no legado isso
-- é setado no momento em que o barbeiro finaliza UM atendimento específico
-- (`baFinishAppt` → `openFeedback('barbeiro')`), não um campo solto do
-- cliente. Em vez de acoplar no fluxo de checkout (`staff_checkout`, já
-- testado e sensível), a avaliação vira uma ação isolada e explícita na
-- ficha: o staff escolhe UM atendimento concluído específico (`p_appt_id`)
-- pra avaliar — nunca "o mais recente" implícito, mesmo erro estrutural
-- que já corrigimos em `staff_crm_marcar_indicacao_dada` (ver
-- 20260912000600_staff_crm_indicacao_fix.sql).
--
-- Autorização: mesma fronteira do resto do staff_crm_* — barbeiro só avalia
-- atendimento que ELE MESMO fez (a.barber_id = v_uid), concluído
-- (a.status = 'concluido'), do cliente resolvido por `p_ref`; admin/vendas
-- livre (podem avaliar em nome de qualquer barbeiro, mesmo padrão de acesso
-- amplo que já têm no resto da ficha).
--
-- Rollback: drop function public.staff_crm_avaliar_atendimento(text, bigint, int, text);
-- Impacto no legado: nenhum (mesmas colunas, RLS de `appointments` já
-- restringe UPDATE a `barber_id = auth.uid()` — não precisou hardening).

create or replace function public.staff_crm_avaliar_atendimento(
  p_ref        text,
  p_appt_id    bigint,
  p_nota       int,
  p_comentario text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_role  text := public._crm_ctx();
  v_kind  text := split_part(coalesce(p_ref, ''), ':', 1);
  v_id    text := split_part(coalesce(p_ref, ''), ':', 2);
  v_cli   public.clients%rowtype;
  v_crm   public.crm_clients%rowtype;
  v_cid   uuid;
  v_appt  public.appointments%rowtype;
  v_coment text;
begin
  if p_appt_id is null or p_nota is null then
    raise exception 'BAD_INPUT' using errcode = 'P0001';
  end if;
  if p_nota < 1 or p_nota > 5 then
    raise exception 'BAD_INPUT' using errcode = 'P0001';
  end if;
  if v_kind not in ('conta', 'crm') or v_id = '' then
    raise exception 'BAD_INPUT' using errcode = 'P0001';
  end if;

  if v_kind = 'conta' then
    if v_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'BAD_INPUT' using errcode = 'P0001';
    end if;
    select * into v_cli from public.clients where id = v_id::uuid;
    if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
    v_cid := v_cli.id;
    select * into v_crm from public.crm_clients where client_id = v_cid and barber_id = v_uid;
  else
    if v_id !~ '^[0-9]+$' then
      raise exception 'BAD_INPUT' using errcode = 'P0001';
    end if;
    select * into v_crm from public.crm_clients where id = v_id::bigint;
    if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
    v_cid := v_crm.client_id;
  end if;

  if v_role = 'barbeiro' then
    if not (
         (v_crm.id is not null and v_crm.barber_id = v_uid)
      or (v_cid is not null and exists (
            select 1 from public.appointments a
            where a.client_id = v_cid and a.barber_id = v_uid))
    ) then
      raise exception 'NOT_FOUND' using errcode = 'P0001';
    end if;
  end if;

  if v_cid is null then
    raise exception 'BAD_INPUT' using errcode = 'P0001';
  end if;

  select * into v_appt from public.appointments where id = p_appt_id;
  if not found or v_appt.client_id is distinct from v_cid then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
  if v_appt.status <> 'concluido' then
    raise exception 'ATENDIMENTO_NAO_CONCLUIDO' using errcode = 'P0001';
  end if;
  -- barbeiro só avalia atendimento que ele mesmo fez; admin/vendas livre
  if v_role = 'barbeiro' and v_appt.barber_id <> v_uid then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;

  v_coment := nullif(trim(both from coalesce(p_comentario, '')), '');
  if v_coment is not null and length(v_coment) > 500 then
    v_coment := left(v_coment, 500);
  end if;

  update public.appointments
     set client_rating = p_nota,
         client_rating_comment = v_coment
   where id = p_appt_id;

  insert into public.crm_access_log (staff_id, ref, acao)
  values (v_uid, p_ref, 'avaliar_cliente');

  return jsonb_build_object(
    'ref', p_ref, 'appt_id', p_appt_id, 'nota', p_nota, 'comentario', v_coment
  );
end;
$$;

revoke execute on function public.staff_crm_avaliar_atendimento(text, bigint, int, text)
  from public, anon, authenticated, service_role;
grant execute on function public.staff_crm_avaliar_atendimento(text, bigint, int, text) to authenticated;

alter table public.crm_access_log drop constraint if exists crm_access_log_acao_check;
alter table public.crm_access_log add constraint crm_access_log_acao_check
  check (acao in (
    'atualizar_contato', 'revelar_telefone', 'vincular_conta',
    'atualizar_plano', 'marcar_brinde', 'marcar_indicacao', 'avaliar_cliente'
  ));
