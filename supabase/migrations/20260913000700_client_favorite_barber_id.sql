-- P1-b — Favorito de barbeiro: migra de texto (`clients.favorite_barber`,
-- frágil — rename órfã o vínculo, dois barbeiros com o mesmo nome são
-- ambíguos) para `favorite_barber_id uuid` (FK real pra `barbers`).
--
-- Preflight ABORTA a migration se:
--   (a) há homônimos no roster HOJE (independe de haver favorito) — a
--       ambiguidade não pode existir de jeito nenhum daqui pra frente;
--   (b) algum favorito (texto) bate com mais de um barbeiro DISTINTO —
--       nota: a query certa conta `count(distinct barber_id)`, não
--       `count(*)` do JOIN (que conta 1 linha por CLIENTE — vários
--       clientes favoritando o MESMO único barbeiro é o caso normal, não
--       um erro; confirmado no lab antes de escrever esta migration).
-- (c) favorito sem barbeiro correspondente é só RELATADO (NOTICE), não
--     aborta — fica com `favorite_barber_id = null`, texto preservado.
--
-- D-P1-7: **opção A** (recomendada pela proposta) — `unique index` no
-- nome do barbeiro (case-insensitive). A partir daqui a ambiguidade
-- **não existe mais**: o caminho texto (`#clientApp` legado) sempre
-- resolve pra no máximo 1 barbeiro.
--
-- Espelho bidirecional (`_clients_sync_favorito`) mantém `favorite_barber`
-- (texto, lido pelo legado) e `favorite_barber_id` (uuid, lido pelo Next)
-- sempre consistentes, nos dois sentidos, incluindo rename de barbeiro
-- (`_barbers_propaga_nome`). Nenhum caminho "escolhe" um barbeiro em caso
-- de ambiguidade — com a unique index, isso nunca acontece; o `raise` no
-- caminho texto fica como defesa em profundidade.
--
-- `favorite_barber_id` NÃO entra na allow-list do `_clients_guard_update`
-- (P1-a) — só a RPC `client_set_favorite_barber` (SECURITY DEFINER,
-- bypassa o guard) escreve nela. PATCH direto do cliente em
-- `favorite_barber_id` continua bloqueado (`PROFILE_IMMUTABLE`,
-- default-deny já existente).
--
-- Rollback:
--   drop trigger clients_sync_favorito on public.clients;
--   drop function public._clients_sync_favorito();
--   drop trigger barbers_propaga_nome on public.barbers;
--   drop function public._barbers_propaga_nome();
--   drop function public.client_set_favorite_barber(uuid);
--   alter table public.clients drop column favorite_barber_id;
--   drop index public.barbers_name_unique;
-- Impacto no legado: nenhum no fluxo normal — `caSavePerfil` continua
-- gravando `favorite_barber` (texto); o espelho preenche `_id` sozinho.

do $$
declare
  v_homonimos int;
  v_ambiguos  int;
  v_orfao     record;
begin
  select count(*) into v_homonimos
    from (select lower(name) from public.barbers group by lower(name) having count(*) > 1) x;
  if v_homonimos > 0 then
    raise exception 'BACKFILL_ABORT: há % nome(s) de barbeiro duplicado(s) (case-insensitive) no roster — resolva antes de rodar esta migration (D-P1-7)', v_homonimos;
  end if;

  select count(*) into v_ambiguos
    from (
      select c.favorite_barber, count(distinct b.id) as n_barbeiros
        from public.clients c
        join public.barbers b on lower(b.name) = lower(c.favorite_barber)
       where c.favorite_barber is not null
       group by c.favorite_barber
      having count(distinct b.id) > 1
    ) x;
  if v_ambiguos > 0 then
    raise exception 'BACKFILL_ABORT: há % favorito(s) de cliente que batem com mais de um barbeiro distinto — resolva antes de rodar esta migration (D-P1-7)', v_ambiguos;
  end if;

  for v_orfao in
    select distinct c.favorite_barber from public.clients c
     where c.favorite_barber is not null
       and not exists (select 1 from public.barbers b where lower(b.name) = lower(c.favorite_barber))
  loop
    raise notice 'favorite_barber órfão (sem barbeiro correspondente, favorite_barber_id ficará null): %', v_orfao.favorite_barber;
  end loop;
end $$;

-- ── D-P1-7 opção A: nome de barbeiro passa a ser único (case-insensitive) ──
create unique index if not exists barbers_name_unique on public.barbers (lower(name));

-- ── coluna nova + backfill (só o inequívoco — a preflight já garantiu) ──
alter table public.clients
  add column if not exists favorite_barber_id uuid references public.barbers(id) on delete set null;

update public.clients c
  set favorite_barber_id = b.id
  from public.barbers b
  where lower(b.name) = lower(c.favorite_barber)
    and c.favorite_barber is not null
    and c.favorite_barber_id is null;

-- ── espelho bidirecional: favorite_barber (texto) ↔ favorite_barber_id (uuid) ──
create or replace function public._clients_sync_favorito()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_ids uuid[]; -- na prática 0 ou 1 elemento (unique index garante), array só por clareza/defesa
begin
  -- lê de `barbers_public` (não de `barbers`) de propósito: essa view já é
  -- lida publicamente pelo app (`fetchEquipe`, roster da landing/perfil) —
  -- é dona `postgres` (bypassrls) com select já concedido a `authenticated`.
  -- A tabela `barbers` crua só tem RLS de leitura pra staff
  -- (`barbers_staff_read`); como este trigger roda `security invoker` (o
  -- cliente autenticado que fez o UPDATE), consultar `barbers` direto
  -- devolveria 0 linhas em silêncio (RLS filtrando, não erro) e o favorito
  -- viraria "órfão" mesmo com o barbeiro existindo — sem precisar de
  -- `security definer` (evita elevar privilégio só pra essa leitura).
  if tg_op = 'INSERT' then
    if new.favorite_barber_id is not null then
      new.favorite_barber := (select b.name from public.barbers_public b where b.id = new.favorite_barber_id);
    elsif new.favorite_barber is not null then
      select array_agg(b.id) into v_ids from public.barbers_public b where lower(b.name) = lower(new.favorite_barber);
      if coalesce(cardinality(v_ids), 0) > 1 then
        raise exception 'FAVORITE_AMBIGUOUS' using errcode = 'P0001';
      elsif coalesce(cardinality(v_ids), 0) = 1 then
        new.favorite_barber_id := v_ids[1];
      end if;
    end if;
    return new;
  end if;

  -- UPDATE: o `_id` muda e o texto não → id → nome (sempre inequívoco).
  if new.favorite_barber_id is distinct from old.favorite_barber_id
     and new.favorite_barber is not distinct from old.favorite_barber then
    new.favorite_barber := (select b.name from public.barbers_public b where b.id = new.favorite_barber_id);
    return new;
  end if;

  -- o texto muda e o `_id` não (caminho do #clientApp legado).
  if new.favorite_barber is distinct from old.favorite_barber
     and new.favorite_barber_id is not distinct from old.favorite_barber_id then
    if new.favorite_barber is null then
      new.favorite_barber_id := null;
      return new;
    end if;
    select array_agg(b.id) into v_ids from public.barbers_public b where lower(b.name) = lower(new.favorite_barber);
    if coalesce(cardinality(v_ids), 0) > 1 then
      raise exception 'FAVORITE_AMBIGUOUS' using errcode = 'P0001'; -- defesa em profundidade — a unique index já impede isso
    elsif coalesce(cardinality(v_ids), 0) = 1 then
      new.favorite_barber_id := v_ids[1];
    else
      new.favorite_barber_id := null; -- rótulo dangling (nome não bate com ninguém)
    end if;
    return new;
  end if;

  -- os dois mudaram juntos → o `_id` vence (caminho do Next é autoritativo).
  if new.favorite_barber_id is distinct from old.favorite_barber_id
     and new.favorite_barber is distinct from old.favorite_barber then
    new.favorite_barber := (select b.name from public.barbers_public b where b.id = new.favorite_barber_id);
    return new;
  end if;

  return new;
end;
$$;

revoke execute on function public._clients_sync_favorito()
  from public, anon, authenticated, service_role;

drop trigger if exists clients_sync_favorito on public.clients;
create trigger clients_sync_favorito
  before insert or update on public.clients
  for each row execute function public._clients_sync_favorito();

-- ── rename de barbeiro propaga pro rótulo texto dos clientes que o têm como favorito ──
create or replace function public._barbers_propaga_nome()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  update public.clients
    set favorite_barber = new.name
    where favorite_barber_id = new.id;
  return new;
end;
$$;

revoke execute on function public._barbers_propaga_nome()
  from public, anon, authenticated, service_role;

drop trigger if exists barbers_propaga_nome on public.barbers;
create trigger barbers_propaga_nome
  after update of name on public.barbers
  for each row execute function public._barbers_propaga_nome();

-- ── RPC: client_set_favorite_barber ─────────────────────────────────────
create or replace function public.client_set_favorite_barber(p_barber_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'NOT_AUTH' using errcode = 'P0001';
  end if;
  if public.barber_role() is not null then
    raise exception 'NOT_CLIENT' using errcode = 'P0001';
  end if;

  if p_barber_id is not null and not exists (
    select 1 from public.barbers where id = p_barber_id and is_barber = true
  ) then
    raise exception 'FAVORITE_INVALID' using errcode = 'P0001';
  end if;

  update public.clients set favorite_barber_id = p_barber_id where id = v_uid;
end;
$$;

revoke execute on function public.client_set_favorite_barber(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.client_set_favorite_barber(uuid)
  to authenticated;
