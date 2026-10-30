-- Bloqueio de agenda pela recepção (role 'vendas'): só com senha de um admin ou do barbeiro dono da agenda.
-- Antes a recepção não tinha permissão nenhuma em agenda_blocks (decisão "D5" da migration 20260901000000) e a tela dava 403.
-- Agora: pode LER os bloqueios, mas gravar/remover só pelas funções abaixo, que conferem a senha no servidor (security definer).
-- A senha é comparada com o hash do login (auth.users) e nunca é guardada; 5 erros em 10 minutos travam a conta.
-- Rollback: drop function public.bloquear_horario(uuid, date, text, text, text, text), public.desbloquear_horario(bigint, text),
--   public._senha_libera(uuid, text); drop table public.bloqueio_tentativas; drop policy agenda_blocks_vendas_select_all,
--   agenda_blocks_vendas_insert_any, agenda_blocks_vendas_delete_any on public.agenda_blocks;

create table if not exists public.bloqueio_tentativas (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  at timestamptz not null default now()
);
alter table public.bloqueio_tentativas enable row level security;   -- sem policy: só as funções abaixo mexem

-- 'ok' | 'senha_invalida' | 'muitas_tentativas'. Vale a senha do dono da agenda (p_alvo) ou a de qualquer admin.
create or replace function public._senha_libera(p_alvo uuid, p_senha text) returns text
language plpgsql security definer set search_path = public, auth, extensions as $$
declare quem uuid := auth.uid(); ok boolean;
begin
  if coalesce(p_senha, '') = '' then return 'senha_invalida'; end if;
  if (select count(*) from public.bloqueio_tentativas where user_id = quem and at > now() - interval '10 minutes') >= 5 then
    return 'muitas_tentativas';
  end if;
  select exists (select 1 from auth.users u join public.barbers b on b.id = u.id
                  where (u.id = p_alvo or b.role = 'admin') and u.encrypted_password is not null
                    and u.encrypted_password = extensions.crypt(p_senha, u.encrypted_password)) into ok;
  if not ok then insert into public.bloqueio_tentativas (user_id) values (quem); return 'senha_invalida'; end if;
  return 'ok';
end $$;

create or replace function public.bloquear_horario(p_barber_id uuid, p_day date, p_start text, p_end text, p_reason text default null, p_senha text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare papel text; r text; novo bigint;
begin
  select role into papel from public.barbers where id = auth.uid();
  if papel is null then raise exception 'sem permissão'; end if;
  if papel = 'barbeiro' and p_barber_id <> auth.uid() then raise exception 'sem permissão'; end if;
  if papel not in ('admin', 'barbeiro', 'vendas') then raise exception 'sem permissão'; end if;
  if papel = 'vendas' then
    r := public._senha_libera(p_barber_id, p_senha);
    if r <> 'ok' then return jsonb_build_object('ok', false, 'erro', r); end if;
  end if;
  begin
    insert into public.agenda_blocks (barber_id, day, start_time, end_time, reason) values (p_barber_id, p_day, p_start, p_end, nullif(trim(p_reason), ''))
    returning id into novo;
  exception when unique_violation then return jsonb_build_object('ok', false, 'erro', 'ja_bloqueado');
            when check_violation then return jsonb_build_object('ok', false, 'erro', 'horario_invalido');
  end;
  return jsonb_build_object('ok', true, 'id', novo);
end $$;

create or replace function public.desbloquear_horario(p_id bigint, p_senha text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare papel text; alvo uuid; r text;
begin
  select role into papel from public.barbers where id = auth.uid();
  if papel not in ('admin', 'barbeiro', 'vendas') then raise exception 'sem permissão'; end if;
  select barber_id into alvo from public.agenda_blocks where id = p_id;
  if alvo is null then return jsonb_build_object('ok', true); end if;
  if papel = 'barbeiro' and alvo <> auth.uid() then raise exception 'sem permissão'; end if;
  if papel = 'vendas' then
    r := public._senha_libera(alvo, p_senha);
    if r <> 'ok' then return jsonb_build_object('ok', false, 'erro', r); end if;
  end if;
  delete from public.agenda_blocks where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

grant execute on function public.bloquear_horario(uuid, date, text, text, text, text), public.desbloquear_horario(bigint, text) to authenticated;
revoke execute on function public.bloquear_horario(uuid, date, text, text, text, text), public.desbloquear_horario(bigint, text), public._senha_libera(uuid, text) from anon, public;

-- A recepção lê os bloqueios; gravar e remover direto na tabela fica fechado (with check / using false): só pelas funções.
create policy agenda_blocks_vendas_select_all on public.agenda_blocks for select to authenticated
  using (exists (select 1 from public.barbers b where b.id = auth.uid() and b.role = 'vendas'));
create policy agenda_blocks_vendas_insert_any on public.agenda_blocks for insert to authenticated with check (false);
create policy agenda_blocks_vendas_delete_any on public.agenda_blocks for delete to authenticated using (false);
