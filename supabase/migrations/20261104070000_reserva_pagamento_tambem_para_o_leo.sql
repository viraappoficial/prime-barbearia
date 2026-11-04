-- Em data de pagamento obrigatório (ex.: dezembro) o horário marcado pelo Léo (service_role) também fica reservado por 30 min e cai se não pagar.
create or replace function public._appointment_payment_reserve()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce((select online_pix_enabled from payment_settings limit 1), false)
     and NEW.status = 'pendente' and NEW.payment_status = 'nenhum'
     and auth.role() in ('anon', 'authenticated', 'service_role')
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
