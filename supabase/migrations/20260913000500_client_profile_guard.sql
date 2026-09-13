-- P1-a — Perfil editável do cliente (editar nome/telefone/idade/Instagram).
--
-- Furo hoje: `clients_self_update` (`USING (auth.uid() = id)`, SEM
-- `WITH CHECK`) deixa o cliente trocar QUALQUER coluna da própria linha
-- via PostgREST direto — inclusive `email` (cópia de `auth.users.email`,
-- diverge da identidade real) e `referral_code` (chave do sistema de
-- indicação, forjável).
--
-- Por que o grant de `authenticated` continua AMPLO (não vira grant por
-- coluna) — mesmo raciocínio do `_appointments_guard_update` (ST-H): o
-- legado (`caSavePerfil` → `primeSaveAccount`, index.html l.1953) faz um
-- upsert com a linha INTEIRA do cache (`id, email, name, phone, age,
-- instagram, favorite_barber, referral_code`). O grant por coluna é
-- checado ANTES do trigger — `grant update (name,phone,age,instagram)`
-- rejeitaria esse upsert na hora (`permission denied for column email`),
-- quebrando o `#clientApp` inteiro, mesmo quando `email`/`referral_code`
-- não mudam de valor. A barreira real é o TRIGGER (compara OLD/NEW,
-- só vê "mudança" quando o valor de fato muda) — não o grant.
-- Cutover (grant por coluna, migration futura documentada, não escrita
-- aqui) só depois de o `#clientApp` legado sair de cena ou o
-- `caSavePerfil` parar de mandar `id`/`email`/`referral_code`.
--
-- Rollback:
--   drop trigger clients_guard_update on public.clients;
--   drop function public._clients_guard_update();
--   drop function public.client_update_profile(text, text, int, text);
--   grant update on public.clients to anon;
-- Impacto no legado: nenhum no fluxo normal — `caSavePerfil` manda
-- `id`/`email`/`referral_code` iguais ao valor atual (o trigger não vê
-- delta nessas colunas, passa). Só uma mudança REAL de `email`/
-- `referral_code` (que o form do legado nunca faz) passaria a ser
-- rejeitada com `PROFILE_IMMUTABLE`.

revoke update on public.clients from anon;

-- ── guard: allow-list de colunas mutáveis pelo cliente, default-deny ────────
create or replace function public._clients_guard_update()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_changed text[];
begin
  if tg_op <> 'UPDATE' then
    return new;
  end if;

  -- migrations/seeds/RPCs SECURITY DEFINER (owner) / console / backend com
  -- chave de serviço fazem a própria validação.
  if current_user in ('postgres', 'supabase_admin', 'service_role') then
    return new;
  end if;

  -- staff (barbeiro/admin/vendas) não é restringido por este guard — não
  -- edita a linha de `clients` de outra pessoa (RLS já barra isso; a linha
  -- do cliente só é editável pelo próprio via `clients_self_update`).
  if public.barber_role() is not null then
    return new;
  end if;

  -- delta DINÂMICO: qualquer coluna cujo valor mudou de fato (inclui
  -- coluna futura → default-deny), igual ao padrão do guard de agenda.
  v_changed := array(
    select k
    from jsonb_each(to_jsonb(new)) as n(k, v)
    where n.v is distinct from (to_jsonb(old) -> n.k)
  );
  if cardinality(v_changed) = 0 then
    return new;
  end if;

  -- allow-list do cliente: nome/telefone/idade/instagram (edição real) +
  -- favorite_barber (texto, só enquanto o #clientApp legado existir — o
  -- sync com favorite_barber_id vem na P1-b).
  if not (v_changed <@ array['name', 'phone', 'age', 'instagram', 'favorite_barber']) then
    raise exception 'PROFILE_IMMUTABLE' using errcode = 'P0001';
  end if;

  return new;
end;
$$;

revoke execute on function public._clients_guard_update()
  from public, anon, authenticated, service_role;

drop trigger if exists clients_guard_update on public.clients;
create trigger clients_guard_update
  before update on public.clients
  for each row execute function public._clients_guard_update();

-- ── RPC: client_update_profile — única porta de escrita de perfil ───────────
create or replace function public.client_update_profile(
  p_name      text,
  p_phone     text,
  p_age       int,
  p_instagram text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid       uuid := auth.uid();
  v_name      text;
  v_phone     text;
  v_instagram text;
begin
  if v_uid is null then
    raise exception 'NOT_AUTH' using errcode = 'P0001';
  end if;
  if public.barber_role() is not null then
    raise exception 'NOT_CLIENT' using errcode = 'P0001';
  end if;

  v_name := nullif(trim(both from coalesce(p_name, '')), '');
  if v_name is null or length(v_name) > 80 then
    raise exception 'PROFILE_INVALID' using errcode = 'P0001';
  end if;

  v_phone := nullif(trim(both from coalesce(p_phone, '')), '');
  if v_phone is not null and (
       length(v_phone) < 8 or length(v_phone) > 20
    or v_phone !~ '^[0-9()+ -]+$'
  ) then
    raise exception 'PROFILE_INVALID' using errcode = 'P0001';
  end if;

  if p_age is not null and (p_age < 1 or p_age > 120) then
    raise exception 'PROFILE_INVALID' using errcode = 'P0001';
  end if;

  v_instagram := nullif(trim(both from coalesce(p_instagram, '')), '');
  if v_instagram is not null then
    v_instagram := regexp_replace(v_instagram, '^@', '');
    if v_instagram !~ '^[A-Za-z0-9._]{1,30}$' then
      raise exception 'PROFILE_INVALID' using errcode = 'P0001';
    end if;
    v_instagram := '@' || v_instagram;
  end if;

  update public.clients
    set name = v_name, phone = v_phone, age = p_age, instagram = v_instagram
    where id = v_uid;
end;
$$;

revoke execute on function public.client_update_profile(text, text, int, text)
  from public, anon, authenticated, service_role;
grant execute on function public.client_update_profile(text, text, int, text)
  to authenticated;
