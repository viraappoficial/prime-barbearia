-- Planos: a comissão passa a seguir o USO (quem atende cada item recebe), não a mensalidade.
--  * plano_itens.valor_unit: quanto vale cada unidade do item dentro do plano (o admin ajusta; o padrão é proporcional aos preços avulsos).
--  * sales.comissao_base: base da comissão da linha (null = o próprio valor). Mensalidade = 0; uso do plano = valor_unit do item.
--  * uso_plano.valor_rateado: o valor_unit no dia do uso (histórico: mudar o parâmetro depois não reescreve o passado).
-- O faturamento não muda: a mensalidade entra uma vez, no pagamento; o uso continua com valor 0.
-- Rollback: alter table sales drop column comissao_base; alter table plano_itens drop column valor_unit; alter table uso_plano drop column valor_rateado;
--   e recriar ativar_assinatura/registrar_uso_plano da migration 20261022000000.

alter table public.sales add column if not exists comissao_base numeric(10,2);
alter table public.plano_itens add column if not exists valor_unit numeric(10,2) check (valor_unit is null or valor_unit >= 0);
alter table public.uso_plano add column if not exists valor_rateado numeric(10,2) not null default 0;

-- Padrão: o valor do plano repartido na proporção do preço avulso de referência (Corte Social, Barba Express, Sobrancelha).
update public.plano_itens pi set valor_unit = round(p.valor * ref.preco / tot.soma, 2)
from public.planos p,
     (values ('corte', 30::numeric), ('barba', 25::numeric), ('sobrancelha', 20::numeric)) as ref(item, preco),
     lateral (select sum(i.qtd * r2.preco) as soma from public.plano_itens i
              join (values ('corte', 30::numeric), ('barba', 25::numeric), ('sobrancelha', 20::numeric)) as r2(item, preco) on r2.item = i.item
              where i.plano_id = p.id) tot
where p.id = pi.plano_id and ref.item = pi.item and pi.valor_unit is null;

create or replace function public.ativar_assinatura(p_assinatura_id bigint, p_nota_id bigint default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare a public.assinaturas%rowtype; hoje date := public._hoje_sp();
begin
  if not public._plano_pode_escrever() then raise exception 'sem permissão'; end if;
  select * into a from public.assinaturas where id = p_assinatura_id for update;
  if not found then raise exception 'assinatura não encontrada'; end if;
  if a.status = 'ativa' then return a.id; end if;
  update public.assinaturas set status = 'encerrada' where client_phone = a.client_phone and status = 'ativa' and fim < hoje;
  if a.status <> 'aguardando_pagamento' then raise exception 'assinatura % não está aguardando pagamento', a.id; end if;
  if exists (select 1 from public.assinaturas x where x.client_phone = a.client_phone and x.status = 'ativa' and x.id <> a.id) then
    raise exception 'o cliente já tem um plano ativo';
  end if;
  update public.assinaturas
     set status = 'ativa', inicio = hoje, fim = hoje + validade_dias - 1, pago_em = now(), nota_id = coalesce(p_nota_id, nota_id)
   where id = a.id;
  insert into public.sales (barber_id, client_name, client_phone, service, value, date, time, nota_id, qty, type, assinatura_id, comissao_base)
  values (a.barber_id, a.client_name, a.client_phone, 'Assinatura — ' || a.plano_nome, a.valor, hoje,
          to_char(now() at time zone 'America/Sao_Paulo', 'HH24:MI'), coalesce(p_nota_id, a.nota_id), 1, 'assinatura', a.id, 0);
  return a.id;
end $$;

create or replace function public.registrar_uso_plano(
  p_assinatura_id bigint, p_items jsonb, p_appointment_id bigint default null, p_nota_id bigint default null, p_barber_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a public.assinaturas%rowtype; it jsonb; v_item text; v_service text; rest integer; sale bigint; unit numeric(10,2);
        cobertos jsonb := '[]'; fora jsonb := '[]'; hoje date := public._hoje_sp(); barbeiro uuid;
begin
  if not public._plano_pode_escrever() then raise exception 'sem permissão'; end if;
  select * into a from public.assinaturas where id = p_assinatura_id for update;
  if not found then raise exception 'assinatura não encontrada'; end if;
  barbeiro := coalesce(p_barber_id, auth.uid(), a.barber_id);
  if a.status <> 'ativa' or hoje < a.inicio or hoje > a.fim then
    return jsonb_build_object('cobertos', '[]'::jsonb, 'fora', p_items, 'motivo', 'plano_inativo');
  end if;
  for it in select * from jsonb_array_elements(p_items) loop
    v_item := it->>'item'; v_service := coalesce(it->>'service', initcap(v_item));
    select s.restante into rest from public.plano_saldo(a.id) s where s.item = v_item;
    if coalesce(rest, 0) > 0 then
      select coalesce(pi.valor_unit, 0) into unit from public.plano_itens pi where pi.plano_id = a.plano_id and pi.item = v_item;
      insert into public.sales (barber_id, client_name, client_phone, service, value, date, time, nota_id, qty, type, assinatura_id, appointment_id, comissao_base)
      values (barbeiro, a.client_name, a.client_phone, v_service, 0, hoje, to_char(now() at time zone 'America/Sao_Paulo', 'HH24:MI'),
              p_nota_id, 1, 'uso_plano', a.id, p_appointment_id, coalesce(unit, 0))
      returning id into sale;
      insert into public.uso_plano (assinatura_id, item, service, appointment_id, nota_id, barber_id, sale_id, valor_rateado)
      values (a.id, v_item, v_service, p_appointment_id, p_nota_id, barbeiro, sale, coalesce(unit, 0));
      cobertos := cobertos || jsonb_build_array(it);
    else
      fora := fora || jsonb_build_array(it);
    end if;
  end loop;
  return jsonb_build_object('cobertos', cobertos, 'fora', fora,
    'saldo', (select coalesce(jsonb_object_agg(s.item, s.restante), '{}') from public.plano_saldo(a.id) s));
end $$;

-- as vendas de mensalidade lançadas pelo admin também não geram comissão
create or replace function public.assinatura_admin_ajustar(
  p_id bigint, p_fim date, p_usados jsonb default null, p_pago boolean default null, p_lancar_venda boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare a public.assinaturas%rowtype; hoje date := public._hoje_sp(); novo_fim date;
begin
  if not public._plano_admin() then raise exception 'só o admin ajusta planos'; end if;
  select * into a from public.assinaturas where id = p_id for update;
  if not found then raise exception 'assinatura não encontrada'; end if;
  if a.status = 'cancelada' then raise exception 'assinatura cancelada'; end if;
  novo_fim := coalesce(p_fim, a.fim);
  if a.inicio is not null and novo_fim < a.inicio then raise exception 'a data final não pode ser antes do início'; end if;
  if p_usados is not null then perform public._plano_definir_usados(a.id, p_usados, coalesce(auth.uid(), a.barber_id)); end if;
  update public.assinaturas
     set fim = novo_fim,
         status = case when novo_fim < hoje then 'encerrada' else 'ativa' end,
         pago_em = case when p_pago is true then coalesce(pago_em, now()) when p_pago is false then null else pago_em end
   where id = a.id;
  if p_lancar_venda and p_pago is true and a.pago_em is null then
    insert into public.sales (barber_id, client_name, client_phone, service, value, date, time, qty, type, assinatura_id, comissao_base)
    values (a.barber_id, a.client_name, a.client_phone, 'Assinatura — ' || a.plano_nome, a.valor, hoje,
            to_char(now() at time zone 'America/Sao_Paulo', 'HH24:MI'), 1, 'assinatura', a.id, 0);
  end if;
end $$;

create or replace function public.assinatura_admin_cadastrar(
  p_plano_id bigint, p_phone text, p_name text, p_fim date, p_usados jsonb default null, p_pago boolean default false,
  p_barber_id uuid default null, p_lancar_venda boolean default false)
returns bigint language plpgsql security definer set search_path = public as $$
declare pl public.planos%rowtype; fone text := public._fone_canon(p_phone); hoje date := public._hoje_sp(); novo bigint; barbeiro uuid;
begin
  if not public._plano_admin() then raise exception 'só o admin cadastra planos'; end if;
  if length(fone) < 10 then raise exception 'telefone inválido'; end if;
  select * into pl from public.planos where id = p_plano_id;
  if not found then raise exception 'plano não encontrado'; end if;
  if p_fim is null or p_fim < hoje then raise exception 'informe uma data final de hoje em diante'; end if;
  barbeiro := coalesce(p_barber_id, auth.uid());
  if barbeiro is null then raise exception 'informe o barbeiro responsável'; end if;
  update public.assinaturas set status = 'encerrada' where client_phone = fone and status = 'ativa' and fim < hoje;
  if exists (select 1 from public.assinaturas where client_phone = fone and status = 'ativa') then raise exception 'o cliente já tem um plano ativo'; end if;
  insert into public.assinaturas (plano_id, plano_nome, valor, validade_dias, client_phone, client_id, client_name, barber_id, origem, forma_pagamento, status, inicio, fim, pago_em)
  values (pl.id, pl.nome, pl.valor, pl.validade_dias, fone, (select c.id from public.clients c where public._fone_canon(c.phone) = fone limit 1),
          coalesce(nullif(trim(p_name), ''), 'Cliente'), barbeiro, 'balcao', 'loja', 'ativa',
          least(hoje, p_fim - pl.validade_dias + 1), p_fim, case when p_pago then now() end)
  returning id into novo;
  if p_usados is not null then perform public._plano_definir_usados(novo, p_usados, barbeiro); end if;
  if p_lancar_venda and p_pago then
    insert into public.sales (barber_id, client_name, client_phone, service, value, date, time, qty, type, assinatura_id, comissao_base)
    values (barbeiro, coalesce(nullif(trim(p_name), ''), 'Cliente'), fone, 'Assinatura — ' || pl.nome, pl.valor, hoje,
            to_char(now() at time zone 'America/Sao_Paulo', 'HH24:MI'), 1, 'assinatura', novo, 0);
  end if;
  return novo;
end $$;

-- o ajuste manual de uso (admin) guarda o valor do dia, mas não vira venda nem comissão (o atendimento foi antes do sistema)
create or replace function public._plano_definir_usados(p_assinatura_id bigint, p_usados jsonb, p_barber uuid)
returns void language plpgsql security definer set search_path = public as $$
declare k text; alvo integer; atual integer; ids bigint[];
begin
  for k in select jsonb_object_keys(coalesce(p_usados, '{}'::jsonb)) loop
    if k not in ('corte', 'barba', 'sobrancelha') then raise exception 'item inválido: %', k; end if;
    alvo := (p_usados ->> k)::integer;
    if alvo is null or alvo < 0 then raise exception 'quantidade inválida para %', k; end if;
    select count(*) into atual from public.uso_plano where assinatura_id = p_assinatura_id and item = k;
    if alvo > atual then
      insert into public.uso_plano (assinatura_id, item, service, barber_id, valor_rateado)
      select p_assinatura_id, k, 'Ajuste manual (admin)', p_barber,
             coalesce((select pi.valor_unit from public.plano_itens pi join public.assinaturas s on s.plano_id = pi.plano_id where s.id = p_assinatura_id and pi.item = k), 0)
      from generate_series(1, alvo - atual);
    elsif alvo < atual then
      select coalesce(array_agg(id), '{}') into ids from (
        select id from public.uso_plano where assinatura_id = p_assinatura_id and item = k
        order by (sale_id is null) desc, used_at desc, id desc limit atual - alvo) t;
      delete from public.sales where id in (select sale_id from public.uso_plano where id = any(ids) and sale_id is not null);
      delete from public.uso_plano where id = any(ids);
    end if;
  end loop;
end $$;
