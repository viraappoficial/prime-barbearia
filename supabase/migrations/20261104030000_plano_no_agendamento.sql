-- Plano no agendamento do site: (1) meu_plano() passa a informar o barbeiro do plano; (2) quem tem plano ativo não entra na
-- reserva de 30 min de "pagamento obrigatório" (o corte do plano não tem o que pagar antes).
create or replace function public.meu_plano() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare a public.assinaturas%rowtype; fone text;
begin
  if auth.uid() is null then return null; end if;
  select public._fone_canon(c.phone) into fone from public.clients c where c.id = auth.uid();
  if fone is null or length(fone) < 10 then return null; end if;
  select * into a from public.assinaturas x
   where x.client_phone = fone and x.status = 'ativa' and public._hoje_sp() between x.inicio and x.fim
   order by x.id desc limit 1;
  if not found then return null; end if;
  return jsonb_build_object('plano', a.plano_nome, 'inicio', a.inicio, 'fim', a.fim, 'pago', a.pago_em is not null,
    'barber_id', a.barber_id, 'barber_nome', (select b.name from public.barbers b where b.id = a.barber_id),
    'itens', (select coalesce(jsonb_agg(jsonb_build_object('item', s.item, 'total', s.total, 'restante', s.restante) order by s.item), '[]'::jsonb)
              from public.plano_saldo(a.id) s));
end $$;

create or replace function public._appointment_payment_reserve()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce((select online_pix_enabled from payment_settings limit 1), false)
     and NEW.status = 'pendente' and NEW.payment_status = 'nenhum'
     and auth.role() in ('anon', 'authenticated')
     and not exists (select 1 from barbers b where b.id = auth.uid())
     and public.payment_required_for(NEW.day)
     and not exists (select 1 from public.assinaturas x join public.clients c on public._fone_canon(c.phone) = x.client_phone
                      where c.id = NEW.client_id and x.status = 'ativa' and public._hoje_sp() between x.inicio and x.fim) then
    NEW.payment_status := 'pendente';
    NEW.reserved_until := now() + interval '30 minutes';
  end if;
  return NEW;
end;
$$;
