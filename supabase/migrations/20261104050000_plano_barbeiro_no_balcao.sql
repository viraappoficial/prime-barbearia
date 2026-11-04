-- No balcão, o plano só cobre o atendimento do barbeiro do plano. Outro barbeiro só com admin ou com autorização aprovada
-- (Nathan, pelo Léo: tabela plano_autorizacoes). Vale no banco, não só na tela.

create or replace function public._plano_pode_com_barbeiro(p_assinatura_id bigint, p_barber uuid, p_appointment_id bigint default null)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare a public.assinaturas%rowtype; dia date;
begin
  if coalesce(auth.role(), 'service_role') = 'service_role' then return true; end if;
  select * into a from public.assinaturas where id = p_assinatura_id;
  if not found then return false; end if;
  if a.barber_id = p_barber then return true; end if;
  if exists (select 1 from public.barbers b where b.id = auth.uid() and b.role = 'admin') then return true; end if;
  if p_appointment_id is not null then select ap.day::date into dia from public.appointments ap where ap.id = p_appointment_id; end if;
  return exists (select 1 from public.plano_autorizacoes z
                  where z.assinatura_id = a.id and z.barber_id = p_barber and z.status = 'aprovada'
                    and (z.day = public._hoje_sp() or z.day = dia));
end $$;
revoke all on function public._plano_pode_com_barbeiro(bigint, uuid, bigint) from public, anon;
grant execute on function public._plano_pode_com_barbeiro(bigint, uuid, bigint) to authenticated;

create or replace function public.registrar_uso_plano(
  p_assinatura_id bigint, p_items jsonb, p_appointment_id bigint default null, p_nota_id bigint default null, p_barber_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a public.assinaturas%rowtype; it jsonb; v_item text; v_service text; rest integer; sale bigint;
        cobertos jsonb := '[]'; fora jsonb := '[]'; hoje date := public._hoje_sp(); barbeiro uuid;
begin
  if not public._plano_pode_escrever() then raise exception 'sem permissão'; end if;
  select * into a from public.assinaturas where id = p_assinatura_id for update;
  if not found then raise exception 'assinatura não encontrada'; end if;
  barbeiro := coalesce(p_barber_id, auth.uid(), a.barber_id);
  if a.status <> 'ativa' or hoje < a.inicio or hoje > a.fim then
    return jsonb_build_object('cobertos', '[]'::jsonb, 'fora', p_items, 'motivo', 'plano_inativo');
  end if;
  if not public._plano_pode_com_barbeiro(a.id, barbeiro, p_appointment_id) then
    return jsonb_build_object('cobertos', '[]'::jsonb, 'fora', p_items, 'motivo', 'barbeiro_diferente');
  end if;
  for it in select * from jsonb_array_elements(p_items) loop
    v_item := it->>'item'; v_service := coalesce(it->>'service', initcap(v_item));
    select s.restante into rest from public.plano_saldo(a.id) s where s.item = v_item;
    if coalesce(rest, 0) > 0 then
      insert into public.sales (barber_id, client_name, client_phone, service, value, date, time, nota_id, qty, type, assinatura_id, appointment_id)
      values (barbeiro, a.client_name, a.client_phone, v_service, 0, hoje, to_char(now() at time zone 'America/Sao_Paulo', 'HH24:MI'),
              p_nota_id, 1, 'uso_plano', a.id, p_appointment_id)
      returning id into sale;
      insert into public.uso_plano (assinatura_id, item, service, appointment_id, nota_id, barber_id, sale_id)
      values (a.id, v_item, v_service, p_appointment_id, p_nota_id, barbeiro, sale);
      cobertos := cobertos || jsonb_build_array(it);
    else
      fora := fora || jsonb_build_array(it);
    end if;
  end loop;
  return jsonb_build_object('cobertos', cobertos, 'fora', fora,
    'saldo', (select coalesce(jsonb_object_agg(s.item, s.restante), '{}') from public.plano_saldo(a.id) s));
end $$;

-- plano_do_cliente passa a informar o barbeiro do plano e quem já tem autorização aprovada (para a tela do balcão explicar e cobrir certo)
create or replace function public.plano_do_cliente(p_phone text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare a public.assinaturas%rowtype;
begin
  if not public._plano_pode_escrever() then raise exception 'sem permissão'; end if;
  select * into a from public.assinaturas x
   where x.client_phone = public._fone_canon(p_phone) and x.status = 'ativa' and public._hoje_sp() between x.inicio and x.fim
   order by x.id desc limit 1;
  if not found then return null; end if;
  return jsonb_build_object('id', a.id, 'plano', a.plano_nome, 'inicio', a.inicio, 'fim', a.fim, 'valor', a.valor,
    'barber_id', a.barber_id, 'barber_nome', (select b.name from public.barbers b where b.id = a.barber_id),
    'autorizados', (select coalesce(jsonb_agg(jsonb_build_object('barber_id', z.barber_id, 'day', z.day)), '[]'::jsonb)
                     from public.plano_autorizacoes z where z.assinatura_id = a.id and z.status = 'aprovada' and z.day >= public._hoje_sp()),
    'saldo', (select coalesce(jsonb_object_agg(s.item, s.restante), '{}') from public.plano_saldo(a.id) s),
    'total', (select coalesce(jsonb_object_agg(s.item, s.total), '{}') from public.plano_saldo(a.id) s));
end $$;
