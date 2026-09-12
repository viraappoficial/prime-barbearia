-- ST-3c.3 — revisão Codex (12/09): `staff_crm_avaliar_atendimento` rejeitava
-- TODO walk-in sem conta (`crm:<id>` com `v_cid` null) com BAD_INPUT — mas
-- `staff_crm_ficha` já lista os atendimentos concluídos desse mesmo walk-in
-- no bloco `avaliacoes` (mesma lógica de casamento por nome usada em
-- `historico`/`recorrencia`, que sempre suportou walk-in). Resultado: o
-- botão "Avaliar" aparecia na ficha, mas salvar sempre falhava.
--
-- Achado [P1]: `avaliacoes` não é gated por `v_cid is not null` (diferente
-- de `brinde`/`indicacao`, que dependem de FK real pra `clients` via
-- `loyalty_gifts`/`referrals`) — `appointments.client_rating` não tem essa
-- dependência, então não havia razão estrutural pra excluir walk-in daqui.
--
-- Fix: a RPC passa a computar `v_mname` (igual à ficha) e aceitar o MESMO
-- atendimento por casamento de nome quando `v_cid` é null — nunca mais um
-- BAD_INPUT incondicional por falta de conta.
--
-- Rollback: reaplicar 20260912000800_staff_crm_avaliar_atendimento.sql.
-- Impacto no legado: nenhum.

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
  v_mname text;
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

  -- chave de casamento por nome (walk-in sem conta) — igual à ficha
  v_mname := lower(coalesce(v_crm.name, v_cli.name, ''));

  select * into v_appt from public.appointments where id = p_appt_id;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if not (
       (v_cid is not null and v_appt.client_id = v_cid)
    or (v_cid is null and v_mname <> '' and lower(v_appt.client_name) = v_mname
        and v_appt.barber_id = coalesce(v_crm.barber_id, v_appt.barber_id))
  ) then
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
