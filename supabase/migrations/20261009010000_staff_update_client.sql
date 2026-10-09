-- Aba "Cadastros" (busca geral + edição de cliente pela equipe). RLS de `clients` deixa
-- vendas/admin LER qualquer linha (clients_readable_by_barbers, já existe), mas não deixa
-- escrever direto — essa RPC é a única porta de escrita, narrow e com checagem de cargo, mesmo
-- padrão das outras (assume_whatsapp_chat, end_attendance etc.).
create or replace function public.staff_update_client(
  p_client_id uuid,
  p_name text,
  p_phone text,
  p_email text,
  p_age int,
  p_instagram text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from barbers b where b.id = auth.uid() and b.role in ('vendas','admin')) then
    raise exception 'sem permissão';
  end if;
  if p_name is null or btrim(p_name) = '' then
    raise exception 'nome obrigatório';
  end if;

  update clients set
    name = p_name,
    phone = p_phone,
    email = p_email,
    age = p_age,
    instagram = p_instagram
  where id = p_client_id;
end;
$$;
revoke all on function public.staff_update_client(uuid, text, text, text, int, text) from public;
grant execute on function public.staff_update_client(uuid, text, text, text, int, text) to authenticated;
