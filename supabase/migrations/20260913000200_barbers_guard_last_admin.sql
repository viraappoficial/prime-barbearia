-- ST-5.2 — revisão Codex: proteger o último admin da equipe de forma
-- ATÔMICA no banco. A versão anterior (checagem no app: `select count(*)
-- where role='admin' and id<>alvo`, depois `update`/`delete` separado) tem
-- uma corrida real — dois admins agindo um sobre o outro ao mesmo tempo
-- (cada um vê o outro como admin ainda, os dois passam na checagem, os
-- dois escrevem) podem zerar os admins da equipe SIMULTANEAMENTE, travando
-- o acesso administrativo pra sempre (ninguém mais passa no guard/RLS de
-- admin pra desfazer).
--
-- Fix: trigger `BEFORE UPDATE OR DELETE` em `barbers`, com
-- `pg_advisory_xact_lock` — serializa qualquer operação concorrente que
-- tentaria remover/rebaixar um admin (a segunda transação só faz sua
-- checagem depois que a primeira já commitou ou desfez, então sempre vê o
-- estado real e final). Substitui a checagem não-atômica do app: agora o
-- app só tenta a escrita e traduz o erro `LAST_ADMIN` (P0001) se o banco
-- recusar.
--
-- Rollback: drop trigger barbers_guard_last_admin on public.barbers;
--           drop function public._barbers_guard_last_admin();
-- Impacto no legado: nenhum (o legado nunca tinha essa proteção atômica —
-- só a checagem de UI, igualmente sujeita à mesma corrida).

create or replace function public._barbers_guard_last_admin()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_removendo_admin boolean;
begin
  if TG_OP = 'DELETE' then
    v_removendo_admin := (OLD.role = 'admin');
  else
    v_removendo_admin := (OLD.role = 'admin' and NEW.role is distinct from 'admin');
  end if;

  if v_removendo_admin then
    -- serializa qualquer operação concorrente que remova/rebaixe admin —
    -- só libera depois que a transação concorrente commitou ou desfez.
    perform pg_advisory_xact_lock(hashtext('barbers_admin_guard')::bigint);
    if not exists (select 1 from public.barbers where role = 'admin' and id <> OLD.id) then
      raise exception 'LAST_ADMIN' using errcode = 'P0001';
    end if;
  end if;

  if TG_OP = 'DELETE' then
    return OLD;
  end if;
  return NEW;
end;
$$;

drop trigger if exists barbers_guard_last_admin on public.barbers;
create trigger barbers_guard_last_admin
  before update or delete on public.barbers
  for each row execute function public._barbers_guard_last_admin();
