-- Planos: o admin cadastra uma assinatura que já existia fora do sistema e ajusta depois (validade, usados, pago).
-- Não mexe nas regras de venda/uso do balcão (vender_plano, registrar_uso_plano). Ajustes de uso ficam em uso_plano como
-- "Ajuste manual" (sale_id nulo, sem venda de R$ 0), então o saldo (plano_saldo) já conta certo.
-- Rollback: drop function public.assinatura_admin_ajustar(bigint, date, jsonb, boolean, boolean),
--   public.assinatura_admin_cadastrar(bigint, text, text, date, jsonb, boolean, uuid, boolean), public._plano_admin();

create or replace function public._plano_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(auth.role(), 'service_role') = 'service_role'
      or exists (select 1 from public.barbers b where b.id = auth.uid() and b.role = 'admin');
$$;

-- Deixa o uso do ciclo com exatamente p_usados = {"corte":n,"barba":n,"sobrancelha":n} (itens que não vierem ficam como estão).
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
      insert into public.uso_plano (assinatura_id, item, service, barber_id)
      select p_assinatura_id, k, 'Ajuste manual (admin)', p_barber from generate_series(1, alvo - atual);
    elsif alvo < atual then
      -- tira os mais recentes (primeiro os ajustes manuais); se tinham venda de R$ 0, a venda sai junto
      select coalesce(array_agg(id), '{}') into ids from (
        select id from public.uso_plano where assinatura_id = p_assinatura_id and item = k
        order by (sale_id is null) desc, used_at desc, id desc limit atual - alvo) t;
      delete from public.sales where id in (select sale_id from public.uso_plano where id = any(ids) and sale_id is not null);
      delete from public.uso_plano where id = any(ids);
    end if;
  end loop;
end $$;

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
  -- recebeu agora e quer lançar no financeiro (só na primeira vez que fica pago)
  if p_lancar_venda and p_pago is true and a.pago_em is null then
    insert into public.sales (barber_id, client_name, client_phone, service, value, date, time, qty, type, assinatura_id)
    values (a.barber_id, a.client_name, a.client_phone, 'Assinatura — ' || a.plano_nome, a.valor, hoje,
            to_char(now() at time zone 'America/Sao_Paulo', 'HH24:MI'), 1, 'assinatura', a.id);
  end if;
end $$;

-- Cadastro de quem já é assinante (veio de fora): ativa, sem venda, com a validade e o uso que o admin informar.
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
    insert into public.sales (barber_id, client_name, client_phone, service, value, date, time, qty, type, assinatura_id)
    values (barbeiro, coalesce(nullif(trim(p_name), ''), 'Cliente'), fone, 'Assinatura — ' || pl.nome, pl.valor, hoje,
            to_char(now() at time zone 'America/Sao_Paulo', 'HH24:MI'), 1, 'assinatura', novo);
  end if;
  return novo;
end $$;

revoke execute on function public._plano_admin(), public._plano_definir_usados(bigint, jsonb, uuid),
  public.assinatura_admin_ajustar(bigint, date, jsonb, boolean, boolean),
  public.assinatura_admin_cadastrar(bigint, text, text, date, jsonb, boolean, uuid, boolean) from anon, public;
grant execute on function public.assinatura_admin_ajustar(bigint, date, jsonb, boolean, boolean),
  public.assinatura_admin_cadastrar(bigint, text, text, date, jsonb, boolean, uuid, boolean) to authenticated;
