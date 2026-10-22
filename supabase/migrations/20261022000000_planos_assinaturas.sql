-- Planos de assinatura (Bronze / Prata / Ouro) — Fase 1: base de dados e regras.
-- Desenho: mockup "Planos Prime". Cada assinatura é UM ciclo de 30 dias (renovar = nova linha em `assinaturas`, ligada por
-- `renovacao_de`). O saldo é calculado: itens do plano menos os usos daquele ciclo. Todas as escritas passam pelas funções
-- abaixo (security definer), que conferem saldo, validade e permissão e fazem tudo numa transação só.
-- Rollback: drop function se existir (vender_plano, ativar_assinatura, registrar_uso_plano, desfazer_uso_plano, plano_saldo,
-- assinatura_ativa); drop table uso_plano, assinaturas, plano_itens, planos; alter table services drop column conta_no_plano;
-- alter table sales drop column assinatura_id; e recriar sales_type_check como (type is null or type = 'produto').

-- 1) Planos oferecidos e o que cada um inclui
create table if not exists public.planos (
  id bigint generated always as identity primary key,
  nome text not null unique,
  valor numeric(10,2) not null check (valor > 0),
  validade_dias integer not null default 30 check (validade_dias > 0),
  ativo boolean not null default true,
  ordem integer not null default 0,
  created_at timestamptz not null default now()
);
create table if not exists public.plano_itens (
  plano_id bigint not null references public.planos(id) on delete cascade,
  item text not null check (item in ('corte', 'barba', 'sobrancelha')),
  qtd integer not null check (qtd > 0),
  primary key (plano_id, item)
);

-- 2) O que cada serviço consome do plano (qualquer corte = 1 corte, qualquer barba = 1 barba; combos consomem um de cada)
alter table public.services
  add column if not exists conta_no_plano text[] not null default '{}';
alter table public.services drop constraint if exists services_conta_no_plano_check;
alter table public.services add constraint services_conta_no_plano_check
  check (conta_no_plano <@ array['corte', 'barba', 'sobrancelha']::text[]);

-- 3) Assinaturas (um ciclo cada) e usos
create table if not exists public.assinaturas (
  id bigint generated always as identity primary key,
  plano_id bigint not null references public.planos(id),
  plano_nome text not null,
  valor numeric(10,2) not null check (valor > 0),             -- valor travado na venda
  validade_dias integer not null,
  client_phone text not null,                                  -- só dígitos
  client_id uuid references public.clients(id) on delete set null,
  client_name text not null,
  barber_id uuid not null references public.barbers(id),       -- quem vendeu (comissão pela % dele)
  origem text not null default 'balcao' check (origem in ('balcao', 'whatsapp', 'app', 'site')),
  forma_pagamento text not null default 'loja' check (forma_pagamento in ('loja', 'pix')),
  status text not null default 'aguardando_pagamento' check (status in ('aguardando_pagamento', 'ativa', 'cancelada', 'encerrada')),
  inicio date,
  fim date,                                                    -- inclusive: inicio + validade_dias - 1
  pago_em timestamptz,
  nota_id bigint,
  renovacao_de bigint references public.assinaturas(id),
  cancelada_em timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists assinaturas_phone_idx on public.assinaturas (client_phone, status);
-- no máximo um ciclo ativo e um aguardando pagamento por telefone
create unique index if not exists assinaturas_uma_ativa on public.assinaturas (client_phone) where status = 'ativa';
create unique index if not exists assinaturas_uma_aguardando on public.assinaturas (client_phone) where status = 'aguardando_pagamento';

create table if not exists public.uso_plano (
  id bigint generated always as identity primary key,
  assinatura_id bigint not null references public.assinaturas(id) on delete restrict,
  item text not null check (item in ('corte', 'barba', 'sobrancelha')),
  service text not null,
  appointment_id bigint references public.appointments(id) on delete set null,
  nota_id bigint,
  barber_id uuid not null references public.barbers(id),
  sale_id bigint references public.sales(id) on delete set null,
  used_at timestamptz not null default now()
);
create index if not exists uso_plano_assinatura_idx on public.uso_plano (assinatura_id);
create index if not exists uso_plano_appointment_idx on public.uso_plano (appointment_id);

-- 4) Vendas: tipos novos e ligação com a assinatura. `uso_plano` é um tipo PRÓPRIO (R$ 0,00): entra no histórico do cliente,
--    mas fica fora de receita, comissão, caixa e ticket médio, que olham só serviço avulso, produto e assinatura.
alter table public.sales add column if not exists assinatura_id bigint references public.assinaturas(id) on delete set null;
alter table public.sales drop constraint if exists sales_type_check;
alter table public.sales add constraint sales_type_check
  check (type is null or type in ('produto', 'assinatura', 'uso_plano'));

-- 5) Permissões: qualquer profissional lê (o plano é da pessoa, não de um barbeiro); a cliente lê só o próprio; escrita só pelas funções
alter table public.planos enable row level security;
alter table public.plano_itens enable row level security;
alter table public.assinaturas enable row level security;
alter table public.uso_plano enable row level security;

drop policy if exists planos_read on public.planos;
create policy planos_read on public.planos for select to authenticated using (true);
drop policy if exists plano_itens_read on public.plano_itens;
create policy plano_itens_read on public.plano_itens for select to authenticated using (true);
drop policy if exists planos_admin_write on public.planos;
create policy planos_admin_write on public.planos for all to authenticated
  using (exists (select 1 from public.barbers b where b.id = auth.uid() and b.role = 'admin'))
  with check (exists (select 1 from public.barbers b where b.id = auth.uid() and b.role = 'admin'));
drop policy if exists plano_itens_admin_write on public.plano_itens;
create policy plano_itens_admin_write on public.plano_itens for all to authenticated
  using (exists (select 1 from public.barbers b where b.id = auth.uid() and b.role = 'admin'))
  with check (exists (select 1 from public.barbers b where b.id = auth.uid() and b.role = 'admin'));
drop policy if exists assinaturas_staff_read on public.assinaturas;
create policy assinaturas_staff_read on public.assinaturas for select to authenticated
  using (exists (select 1 from public.barbers b where b.id = auth.uid()));
drop policy if exists assinaturas_own_read on public.assinaturas;
create policy assinaturas_own_read on public.assinaturas for select to authenticated using (client_id = auth.uid());
drop policy if exists uso_plano_staff_read on public.uso_plano;
create policy uso_plano_staff_read on public.uso_plano for select to authenticated
  using (exists (select 1 from public.barbers b where b.id = auth.uid()));
grant select on public.planos, public.plano_itens, public.assinaturas, public.uso_plano to authenticated;
grant insert, update, delete on public.planos, public.plano_itens to authenticated;

-- 6) Planos atuais do site (os mesmos valores e itens do PLAN_TIERS)
insert into public.planos (nome, valor, ordem) values
  ('Plano Bronze', 99.90, 1), ('Plano Prata', 189.90, 2), ('Plano Ouro', 289.90, 3)
on conflict (nome) do nothing;
insert into public.plano_itens (plano_id, item, qtd)
select p.id, i.item, i.qtd from public.planos p
join (values
  ('Plano Bronze', 'corte', 2), ('Plano Bronze', 'sobrancelha', 1),
  ('Plano Prata', 'corte', 4), ('Plano Prata', 'barba', 2), ('Plano Prata', 'sobrancelha', 2),
  ('Plano Ouro', 'corte', 4), ('Plano Ouro', 'barba', 4), ('Plano Ouro', 'sobrancelha', 2)
) as i(nome, item, qtd) on i.nome = p.nome
on conflict do nothing;

update public.services set conta_no_plano = '{corte}' where name in ('Corte Social', 'Corte Degradê', 'Corte Raspado', 'Corte Infantil');
update public.services set conta_no_plano = '{barba}' where name in ('Barba Express', 'Barbaterapia');
update public.services set conta_no_plano = '{sobrancelha}' where name = 'Sobrancelha';
update public.services set conta_no_plano = '{corte,barba}' where name in ('Corte e Barba', 'Social e Barba', 'Raspado e Barba');
update public.services set conta_no_plano = '{corte,sobrancelha}' where name = 'Corte e Sobrancelha';
update public.services set conta_no_plano = '{corte,barba,sobrancelha}' where name = 'Corte, Barba e Sobrancelha';

-- 7) Funções ---------------------------------------------------------------------------------------------------------------

-- "service_role" (Edge Functions e SQL do painel, sem JWT) sempre pode; profissional logado também; o resto não.
create or replace function public._plano_pode_escrever() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(auth.role(), 'service_role') = 'service_role'
      or exists (select 1 from public.barbers b where b.id = auth.uid());
$$;

create or replace function public._hoje_sp() returns date
language sql stable as $$ select (now() at time zone 'America/Sao_Paulo')::date $$;

-- Saldo de UM ciclo: o que o plano inclui, o que já foi usado e o que resta.
create or replace function public.plano_saldo(p_assinatura_id bigint)
returns table (item text, total integer, usado integer, restante integer)
language sql stable security definer set search_path = public as $$
  select pi.item, pi.qtd,
         (select count(*)::int from public.uso_plano u where u.assinatura_id = a.id and u.item = pi.item),
         pi.qtd - (select count(*)::int from public.uso_plano u where u.assinatura_id = a.id and u.item = pi.item)
  from public.assinaturas a join public.plano_itens pi on pi.plano_id = a.plano_id
  where a.id = p_assinatura_id
  order by pi.item;
$$;

-- Assinatura ativa e dentro da validade de um telefone (só dígitos); null se não tem.
create or replace function public.assinatura_ativa(p_phone text) returns bigint
language sql stable security definer set search_path = public as $$
  select a.id from public.assinaturas a
  where a.client_phone = regexp_replace(coalesce(p_phone, ''), '\D', '', 'g')
    and a.status = 'ativa' and public._hoje_sp() between a.inicio and a.fim
  order by a.id desc limit 1;
$$;

-- Ativa uma assinatura paga (loja ou Pix): começa hoje, dura validade_dias, e lança a mensalidade como venda
-- `assinatura` do barbeiro que vendeu (a comissão sai pela % dele, como qualquer venda).
create or replace function public.ativar_assinatura(p_assinatura_id bigint, p_nota_id bigint default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare a public.assinaturas%rowtype; hoje date := public._hoje_sp();
begin
  if not public._plano_pode_escrever() then raise exception 'sem permissão'; end if;
  select * into a from public.assinaturas where id = p_assinatura_id for update;
  if not found then raise exception 'assinatura não encontrada'; end if;
  if a.status = 'ativa' then return a.id; end if;                       -- já ativada (Pix e loja ao mesmo tempo)
  update public.assinaturas set status = 'encerrada' where client_phone = a.client_phone and status = 'ativa' and fim < hoje;
  if a.status <> 'aguardando_pagamento' then raise exception 'assinatura % não está aguardando pagamento', a.id; end if;
  if exists (select 1 from public.assinaturas x where x.client_phone = a.client_phone and x.status = 'ativa' and x.id <> a.id) then
    raise exception 'o cliente já tem um plano ativo';
  end if;
  update public.assinaturas
     set status = 'ativa', inicio = hoje, fim = hoje + validade_dias - 1, pago_em = now(), nota_id = coalesce(p_nota_id, nota_id)
   where id = a.id;
  insert into public.sales (barber_id, client_name, client_phone, service, value, date, time, nota_id, qty, type, assinatura_id)
  values (a.barber_id, a.client_name, a.client_phone, 'Assinatura — ' || a.plano_nome, a.valor, hoje,
          to_char(now() at time zone 'America/Sao_Paulo', 'HH24:MI'), coalesce(p_nota_id, a.nota_id), 1, 'assinatura', a.id);
  return a.id;
end $$;

-- Cria a assinatura. `p_pago` true (recebeu no balcão agora) já ativa; false fica aguardando pagamento (Pix ou "pagar na loja").
create or replace function public.vender_plano(
  p_plano_id bigint, p_phone text, p_name text, p_client_id uuid, p_barber_id uuid,
  p_origem text default 'balcao', p_forma text default 'loja', p_pago boolean default false, p_nota_id bigint default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare pl public.planos%rowtype; fone text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'); novo bigint;
begin
  if not public._plano_pode_escrever() then raise exception 'sem permissão'; end if;
  if length(fone) < 10 then raise exception 'telefone inválido'; end if;
  select * into pl from public.planos where id = p_plano_id and ativo;
  if not found then raise exception 'plano não encontrado ou desativado'; end if;
  update public.assinaturas set status = 'encerrada' where client_phone = fone and status = 'ativa' and fim < public._hoje_sp();
  if exists (select 1 from public.assinaturas where client_phone = fone and status = 'ativa') then
    raise exception 'o cliente já tem um plano ativo';
  end if;
  -- troca o pedido pendente anterior (ele escolheu outro plano ou outra forma de pagar)
  update public.assinaturas set status = 'cancelada', cancelada_em = now() where client_phone = fone and status = 'aguardando_pagamento';
  insert into public.assinaturas (plano_id, plano_nome, valor, validade_dias, client_phone, client_id, client_name, barber_id, origem, forma_pagamento, nota_id)
  values (pl.id, pl.nome, pl.valor, pl.validade_dias, fone, p_client_id, coalesce(nullif(trim(p_name), ''), 'Cliente'), p_barber_id, p_origem, p_forma, p_nota_id)
  returning id into novo;
  if p_pago then perform public.ativar_assinatura(novo, p_nota_id); end if;
  return novo;
end $$;

-- Baixa do saldo no fechamento do atendimento. p_items: [{"item":"corte","service":"Corte Social"}, ...].
-- Cobre o que tem saldo (um item de cada vez, na ordem recebida) e devolve o que ficou de fora para o balcão cobrar pelo
-- preço avulso. Tudo ou nada por chamada; trava a assinatura, então dois fechamentos ao mesmo tempo não gastam o mesmo saldo.
-- Cada item usado gera uma linha em uso_plano e uma venda `uso_plano` de R$ 0,00 (histórico do cliente, fora do financeiro).
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

-- Desfaz os usos de um atendimento (desfazer/estorno): devolve o saldo e apaga o histórico de uso.
create or replace function public.desfazer_uso_plano(p_appointment_id bigint default null, p_nota_id bigint default null)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer; ids bigint[];
begin
  if not public._plano_pode_escrever() then raise exception 'sem permissão'; end if;
  if p_appointment_id is null and p_nota_id is null then raise exception 'informe o atendimento ou a nota'; end if;
  select coalesce(array_agg(sale_id), '{}') into ids from public.uso_plano
   where (p_appointment_id is not null and appointment_id = p_appointment_id) or (p_nota_id is not null and nota_id = p_nota_id);
  delete from public.uso_plano
   where (p_appointment_id is not null and appointment_id = p_appointment_id) or (p_nota_id is not null and nota_id = p_nota_id);
  get diagnostics n = row_count;
  delete from public.sales where id = any(ids);
  return n;
end $$;

grant execute on function public.plano_saldo(bigint), public.assinatura_ativa(text),
  public.vender_plano(bigint, text, text, uuid, uuid, text, text, boolean, bigint), public.ativar_assinatura(bigint, bigint),
  public.registrar_uso_plano(bigint, jsonb, bigint, bigint, uuid), public.desfazer_uso_plano(bigint, bigint) to authenticated;
revoke execute on function public.vender_plano(bigint, text, text, uuid, uuid, text, text, boolean, bigint), public.ativar_assinatura(bigint, bigint),
  public.registrar_uso_plano(bigint, jsonb, bigint, bigint, uuid), public.desfazer_uso_plano(bigint, bigint) from anon, public;
