-- ST-1b.3 — encaixe do STAFF (agendamento fora da grade, mas SEM overbooking).
--
-- Legado: `baSaveEncaixe` faz `INSERT` direto (`barbers_insert_own`) com
-- `is_encaixe=true`, `status='confirmado'`, **duração digitada no browser** e
-- **zero checagem de sobreposição**. Cliente por nome; walk-in cria `crm_clients`
-- (dedupe por nome, client-side, arbitrário).
--
-- Esta RPC:
--   - papel/posse: `_staff_can_book_for(p_barber_id, true)` (barbeiro só a
--     própria agenda; admin/vendas escopo global — `appointments_vendas_insert`);
--   - `p_client_ref jsonb` = `{"mode":"account","id":<uuid>}` ou
--     `{"mode":"walkin","name":..,"phone":..}` — validada como OBJETO + `mode`
--     allowlist + UUID por REGEX antes de qualquer `::uuid` (nunca `22P02` cru →
--     tudo vira `CLIENT_INVALID` P0001);
--   - walk-in: resolução DETERMINÍSTICA e CONCORRENTE-SEGURA — 2
--     `pg_advisory_xact_lock` (`'crm|<barber>|tel|<telefone>'` e
--     `'crm|<barber>|nom|<nome>'`, ordem fixa, namespace ≠ do lock de agenda)
--     ANTES do lookup; telefone primeiro; nome só se ÚNICO e sem telefone
--     conflitante; ambiguidade → `WALKIN_CONFLICT` (nunca `LIMIT 1`, nunca
--     palpite);
--   - **serviços por ID**; nome + duração resolvidos no servidor
--     (`_validate_services`);
--   - `is_encaixe=true`, `status='confirmado'`; horário FORA da grade permitido
--     (`p_grid_aligned=false`), mas a sobreposição de intervalo vale →
--     `SLOT_TAKEN` (D6 da ST-H; is_encaixe não é isento);
--   - `p_notes` normalizado (btrim, colapsa espaços, corta em 500);
--   - notif `encaixe` ao cliente na transação — só se conta E `p_notify`.
--
-- Sem WhatsApp (a notif in-app é o canal).
--
-- `SECURITY DEFINER`, `search_path=''`. `revoke execute` de todos → `grant` só a
-- `authenticated`.
--
-- Rollback: drop function public.staff_book_encaixe(uuid, jsonb, date, text, bigint[], text, boolean);
-- Impacto no legado: nenhum — o `#barberApp` segue no INSERT direto.

create or replace function public.staff_book_encaixe(
  p_barber_id   uuid,
  p_client_ref  jsonb,
  p_day         date,
  p_time        text,
  p_service_ids bigint[],
  p_notes       text default null,
  p_notify      boolean default true
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_mode           text;
  v_raw            text;
  v_client_id      uuid;
  v_client_name    text;
  v_client_email   text;
  v_name           text;
  v_phone          text;
  v_by_phone       bigint[];
  v_names_by_phone text[];
  v_by_name        bigint[];
  v_phones_by_name text[];
  v_crm_id         bigint;
  v_notes          text;
  v_names          text[];
  v_dur            int;
  v_new_id         bigint;
  v_barber_name    text;
  v_new            public.appointments%rowtype;
begin
  -- 1. papel/posse (NOT_AUTH / NOT_STAFF / NOT_ALLOWED)
  perform public._staff_can_book_for(p_barber_id, true);

  -- 2. FORMA de p_client_ref — nada de erro cru do Postgres escapando
  if p_client_ref is null or jsonb_typeof(p_client_ref) <> 'object' then
    raise exception 'CLIENT_INVALID' using errcode = 'P0001';
  end if;
  v_mode := p_client_ref ->> 'mode';
  if v_mode is null or v_mode not in ('account', 'walkin') then
    raise exception 'CLIENT_INVALID' using errcode = 'P0001';
  end if;

  -- 3. resolve o cliente
  if v_mode = 'account' then
    v_raw := p_client_ref ->> 'id';
    if v_raw is null or v_raw !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'CLIENT_INVALID' using errcode = 'P0001';   -- nunca ::uuid cru (22P02)
    end if;
    v_client_id := v_raw::uuid;
    select coalesce(c.name, c.email, 'Cliente'), c.email
      into v_client_name, v_client_email
    from public.clients c where c.id = v_client_id;
    if not found then
      raise exception 'CLIENT_INVALID' using errcode = 'P0001';
    end if;

  else  -- walkin
    v_name  := btrim(coalesce(p_client_ref ->> 'name', ''));
    if char_length(v_name) < 1 or char_length(v_name) > 80 then
      raise exception 'WALKIN_INVALID' using errcode = 'P0001';
    end if;
    v_phone := public.normalize_phone_br(p_client_ref ->> 'phone');
    if v_phone is null or v_phone !~ '^[0-9]{10,11}$' then
      raise exception 'WALKIN_INVALID' using errcode = 'P0001';
    end if;

    -- (0) locks de CRM — ANTES de qualquer select/insert em crm_clients.
    --     ordem fixa (tel → nom); namespace 'crm|' ≠ 'agenda|' do núcleo.
    perform pg_advisory_xact_lock(
      hashtextextended('crm|' || p_barber_id::text || '|tel|' || v_phone, 0));
    perform pg_advisory_xact_lock(
      hashtextextended('crm|' || p_barber_id::text || '|nom|' || lower(v_name), 0));

    -- (a) casa por TELEFONE primeiro
    select array_agg(id order by id), array_agg(name order by id)
      into v_by_phone, v_names_by_phone
    from public.crm_clients
    where barber_id = p_barber_id
      and phone is not null
      and public.normalize_phone_br(phone) = v_phone;

    if coalesce(cardinality(v_by_phone), 0) = 1 then
      if lower(v_names_by_phone[1]) <> lower(v_name) then
        raise exception 'WALKIN_CONFLICT' using errcode = 'P0001';   -- mesmo tel, nome diferente
      end if;
      v_crm_id := v_by_phone[1];
    elsif coalesce(cardinality(v_by_phone), 0) > 1 then
      raise exception 'WALKIN_CONFLICT' using errcode = 'P0001';      -- carteira inconsistente
    else
      -- (b) sem telefone correspondente — casa por NOME
      select array_agg(id order by id), array_agg(phone order by id)
        into v_by_name, v_phones_by_name
      from public.crm_clients
      where barber_id = p_barber_id and lower(name) = lower(v_name);

      if coalesce(cardinality(v_by_name), 0) = 0 then
        insert into public.crm_clients (barber_id, name, phone)
        values (p_barber_id, v_name, v_phone)
        returning id into v_crm_id;
      elsif coalesce(cardinality(v_by_name), 0) = 1 then
        v_crm_id := v_by_name[1];
        if v_phones_by_name[1] is null then
          update public.crm_clients set phone = v_phone where id = v_crm_id;
        else
          -- telefone não-null (⇒ ≠ v_phone, senão (a) teria pego) → conflito
          raise exception 'WALKIN_CONFLICT' using errcode = 'P0001';
        end if;
      else
        raise exception 'WALKIN_CONFLICT' using errcode = 'P0001';    -- homônimos
      end if;
    end if;

    v_client_id    := null;
    v_client_name  := v_name;
    v_client_email := null;
  end if;

  -- 4. p_notes normalizado (btrim, colapsa runs de 2+ espaços/quebras, corta 500)
  v_notes := left(
    regexp_replace(nullif(btrim(coalesce(p_notes, '')), ''), '\s{2,}', ' ', 'g'),
    500
  );

  -- 5. serviços resolvidos no SERVIDOR (nome + duração)
  select o_names, o_dur into v_names, v_dur
  from public._validate_services(p_service_ids);   -- → SERVICE_INVALID

  -- 6. cria o encaixe
  v_new_id := public._staff_insert_appointment(
    p_barber_id     => p_barber_id,
    p_day           => p_day,
    p_time          => p_time,
    p_service_names => v_names,
    p_duration      => v_dur,
    p_client_id     => v_client_id,
    p_client_name   => v_client_name,
    p_client_email  => v_client_email,
    p_is_encaixe    => true,
    p_status        => 'confirmado',
    p_notes         => v_notes,
    p_grid_aligned  => false               -- encaixe = fora da grade
  );

  -- 7. notif ao cliente — só se conta E p_notify
  if p_notify and v_client_id is not null then
    select * into v_new from public.appointments where id = v_new_id;
    select b.name into v_barber_name from public.barbers b where b.id = p_barber_id;
    insert into public.notifications
      (for_role, recipient_client_id, type, appt_id, text)
    values
      ('client', v_client_id, 'encaixe', v_new_id,
       coalesce(v_barber_name, 'O barbeiro') || ' encaixou você: '
       || array_to_string(v_names, ' + ')
       || ' — ' || v_new.day_label || ' às ' || p_time);
  end if;

  return v_new_id;
end;
$$;

revoke execute on function public.staff_book_encaixe(uuid, jsonb, date, text, bigint[], text, boolean)
  from public, anon, authenticated, service_role;
grant execute on function public.staff_book_encaixe(uuid, jsonb, date, text, bigint[], text, boolean)
  to authenticated;
