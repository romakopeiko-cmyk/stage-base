begin;

create schema if not exists stage_operations;
revoke all on schema stage_operations from public;
grant usage on schema stage_operations to authenticated;

create index if not exists stage_reservation_items_asset_idx
  on public.reservation_items (asset_id, reservation_id);

create function stage_operations.reservation_asset_visible(current_show uuid, warehouse uuid, marketing boolean)
returns boolean
language sql stable security invoker
set search_path = ''
as $$
  select public.has_permission('assets.view')
    and public.has_show_access(current_show)
    and public.has_warehouse_access(warehouse)
    and (not marketing or public.has_permission('assets.marketing'))
    and exists (
      select 1 from public.profiles p join public.roles r on r.id = p.role_id
      where p.id = auth.uid() and p.is_active
        and r.code in ('executive_producer', 'creative_producer', 'director', 'finance_director',
          'warehouse_manager', 'line_producer', 'show_admin', 'employee')
    );
$$;

create function stage_operations.reservation_decision_allowed(reservation uuid, permission_code text)
returns boolean
language sql stable security invoker
set search_path = ''
as $$
  select public.has_permission(permission_code)
    and not exists (
      select 1 from public.reservation_items i join public.assets a on a.id = i.asset_id
      where i.reservation_id = reservation and a.is_marketing_asset
        and not public.has_permission('assets.marketing')
    )
    and (
      exists (
        select 1 from public.profiles p join public.roles r on r.id = p.role_id
        where p.id = auth.uid() and p.is_active and r.code = 'executive_producer'
      )
      or (
        exists (
          select 1 from public.reservation_items i where i.reservation_id = reservation
        )
        and not exists (
          select 1 from public.reservation_items i join public.assets a on a.id = i.asset_id
          where i.reservation_id = reservation
            and (
              coalesce(a.original_show_id, a.show_id) is null
              or not public.has_show_access(coalesce(a.original_show_id, a.show_id))
              or not public.has_warehouse_access(a.warehouse_id)
            )
        )
      )
    );
$$;

create function stage_operations.assert_capacity(asset uuid, period_start timestamptz, period_end timestamptz, amount numeric, ignored uuid)
returns void
language plpgsql security invoker
set search_path = ''
as $$
declare
  stock public.assets%rowtype;
begin
  if current_setting('transaction_isolation') <> 'read committed' then
    raise exception 'Для бронювання потрібна транзакція READ COMMITTED';
  end if;
  select * into stock from public.assets where id = asset for update;
  if not found or stock.is_archived or amount <= 0 or amount > stock.quantity
      or (stock.tracking_type <> 'consumable' and amount <> 1) then
    raise exception 'Недоступна кількість майна';
  end if;

  if exists (
    with occupied as (
      select i.quantity, r.start_date, r.end_date
      from public.reservation_items i join public.reservations r on r.id = i.reservation_id
      where i.asset_id = asset and r.id is distinct from ignored
        and r.status in ('approved', 'issued')
        and r.start_date < period_end and r.end_date > period_start
    ),
    points as (
      select period_start as at
      union
      select start_date from occupied where start_date > period_start
    )
    select 1 from points p join occupied o on o.start_date <= p.at and o.end_date > p.at
    group by p.at
    having sum(o.quantity) + amount > stock.quantity
  ) then
    raise exception 'Майно вже заброньоване на обраний час або доступної кількості недостатньо';
  end if;
end;
$$;

create function stage_operations.create_reservation(
  destination uuid, responsible uuid, period_start timestamptz, period_end timestamptz,
  items jsonb, purpose_text text
)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  reservation uuid;
  item record;
begin
  if actor is null or not public.has_permission('reservations.create')
      or not public.has_show_access(destination) then
    raise exception 'Недостатньо прав для створення бронювання' using errcode = '42501';
  end if;
  if period_start is null or period_end is null or not isfinite(period_start) or not isfinite(period_end)
      or period_end <= period_start or period_end <= now()
      or jsonb_typeof(items) is distinct from 'array' then
    raise exception 'Перевірте період та список майна';
  end if;
  if jsonb_array_length(items) not between 1 and 100
      or not exists (select 1 from public.shows where id = destination and status = 'active')
      or not exists (
        select 1 from public.profiles p join public.roles r on r.id = p.role_id
        where p.id = responsible and p.is_active and (
          p.id = actor or r.code in ('executive_producer','creative_producer','director','finance_director','warehouse_manager')
          or exists (select 1 from public.user_show_access a where a.user_id = p.id and a.show_id = destination)
        )
      ) then
    raise exception 'Перевірте шоу, відповідального та список майна';
  end if;

  insert into public.reservations(show_id, requested_by, responsible_id, start_date, end_date, purpose)
  values (destination, actor, responsible, period_start, period_end, nullif(btrim(purpose_text), ''))
  returning id into reservation;

  for item in select * from jsonb_to_recordset(items) as i(asset_id uuid, quantity numeric) order by asset_id
  loop
    if item.quantity is null or item.quantity::text in ('NaN','Infinity','-Infinity')
        or not exists (
          select 1 from public.assets a where a.id = item.asset_id
            and stage_operations.reservation_asset_visible(a.show_id, a.warehouse_id, a.is_marketing_asset)
        ) then
      raise exception 'Майно або кількість недоступні';
    end if;
    perform stage_operations.assert_capacity(item.asset_id, period_start, period_end, item.quantity, reservation);
    insert into public.reservation_items(reservation_id, asset_id, quantity)
      values (reservation, item.asset_id, item.quantity);
  end loop;

  insert into public.audit_log(actor_id, action_type, entity_type, entity_id, show_id, description)
    values (actor, 'reservation_requested', 'reservation', reservation, destination, 'Створено запит на бронювання');
  return reservation;
end;
$$;

create function stage_operations.decide_reservation(reservation uuid, approve boolean, reason text)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  request public.reservations%rowtype;
  item record;
begin
  if actor is null or approve is null then
    raise exception 'Недостатньо прав' using errcode = '42501';
  end if;

  select * into request from public.reservations where id = reservation for update;
  if not found or not stage_operations.reservation_decision_allowed(
      reservation, case when approve then 'reservations.approve' else 'reservations.reject' end
  ) then
    raise exception 'Недостатньо прав для розгляду бронювання' using errcode = '42501';
  end if;
  if request.status <> 'pending' then
    raise exception 'Запит уже розглянуто';
  end if;

  if approve then
    if request.end_date <= now() or not exists (
      select 1 from public.reservation_items where reservation_id = reservation
    ) then
      raise exception 'Період бронювання завершився або запит порожній';
    end if;
    for item in
      select i.asset_id, i.quantity from public.reservation_items i
      where i.reservation_id = reservation order by i.asset_id
    loop
      perform stage_operations.assert_capacity(item.asset_id, request.start_date, request.end_date, item.quantity, reservation);
    end loop;
    -- Scope may have changed while the asset locks were being acquired.
    if not stage_operations.reservation_decision_allowed(reservation, 'reservations.approve') then
      raise exception 'Недостатньо прав для погодження бронювання' using errcode = '42501';
    end if;
  elsif nullif(btrim(reason), '') is null then
    raise exception 'Вкажіть причину відмови';
  end if;

  update public.reservations set
    status = case when approve then 'approved' else 'rejected' end,
    approved_by = case when approve then actor end,
    approved_at = case when approve then now() end,
    rejection_reason = case when not approve then btrim(reason) end,
    updated_at = now()
  where id = reservation;

  insert into public.audit_log(actor_id, action_type, entity_type, entity_id, show_id, description)
    values (actor, case when approve then 'reservation_approved' else 'reservation_rejected' end,
      'reservation', reservation, request.show_id,
      case when approve then 'Бронювання погоджено' else 'У бронюванні відмовлено' end);
  insert into public.notifications(recipient_id, notification_type, title, message, entity_type, entity_id)
    values (request.requested_by, 'reservation_decision', 'Рішення щодо бронювання',
      case when approve then 'Бронювання погоджено.' else 'У бронюванні відмовлено: ' || btrim(reason) end,
      'reservation', reservation);
end;
$$;

create function public.stage_create_reservation(
  p_show uuid, p_responsible uuid, p_start timestamptz, p_end timestamptz, p_items jsonb, p_purpose text
)
returns uuid language sql security invoker set search_path = ''
as $$ select stage_operations.create_reservation(p_show, p_responsible, p_start, p_end, p_items, p_purpose); $$;

create function public.stage_decide_reservation(p_reservation uuid, p_approve boolean, p_reason text)
returns void language sql security invoker set search_path = ''
as $$ select stage_operations.decide_reservation(p_reservation, p_approve, p_reason); $$;

create function stage_operations.list_reservations()
returns jsonb
language sql stable security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'can_create', auth.uid() is not null and public.has_permission('reservations.create'),
    'reservations', coalesce((
      select jsonb_agg(to_jsonb(request) order by request.start_date, request.id)
      from (
        select r.id, s.name as show_name, r.status, r.start_date, r.end_date, r.purpose, r.rejection_reason,
          p.full_name as responsible_name,
          r.status = 'pending' and stage_operations.reservation_decision_allowed(r.id, 'reservations.approve') as can_approve,
          r.status = 'pending' and stage_operations.reservation_decision_allowed(r.id, 'reservations.reject') as can_reject,
          coalesce((
            select jsonb_agg(jsonb_build_object(
              'name', a.name, 'number', a.inventory_number, 'quantity', i.quantity, 'unit', a.unit
            ) order by a.name)
            from public.reservation_items i join public.assets a on a.id = i.asset_id
            where i.reservation_id = r.id and (
              stage_operations.reservation_decision_allowed(r.id, 'reservations.approve')
              or stage_operations.reservation_decision_allowed(r.id, 'reservations.reject')
              or stage_operations.reservation_asset_visible(a.show_id, a.warehouse_id, a.is_marketing_asset)
            )
          ), '[]'::jsonb) as items
        from public.reservations r
        join public.shows s on s.id = r.show_id
        join public.profiles p on p.id = r.responsible_id
        where auth.uid() is not null and (
          (public.has_permission('reservations.view') and public.has_show_access(r.show_id))
          or (r.requested_by = auth.uid() and public.has_permission('reservations.create'))
          or stage_operations.reservation_decision_allowed(r.id, 'reservations.approve')
          or stage_operations.reservation_decision_allowed(r.id, 'reservations.reject')
        )
        order by (r.end_date <= now()), r.start_date, r.id
        limit 100
      ) request
    ), '[]'::jsonb)
  );
$$;

create function stage_operations.reservation_responsibles(destination uuid)
returns table(id uuid, name text)
language sql stable security definer
set search_path = ''
as $$
  select p.id, p.full_name
  from public.profiles p join public.roles r on r.id = p.role_id
  where auth.uid() is not null and public.has_permission('reservations.create')
    and public.has_show_access(destination) and p.is_active
    and (
      p.id = auth.uid()
      or r.code in ('executive_producer','creative_producer','director','finance_director','warehouse_manager')
      or exists (select 1 from public.user_show_access a where a.user_id = p.id and a.show_id = destination)
    )
  order by p.full_name, p.id;
$$;

create function public.stage_list_reservations()
returns jsonb language sql stable security invoker set search_path = ''
as $$ select stage_operations.list_reservations(); $$;

create function public.stage_reservation_responsibles(p_show uuid)
returns table(id uuid, name text) language sql stable security invoker set search_path = ''
as $$ select * from stage_operations.reservation_responsibles(p_show); $$;

revoke execute on all functions in schema stage_operations from public, anon, authenticated;
revoke execute on function public.stage_create_reservation(uuid,uuid,timestamptz,timestamptz,jsonb,text),
  public.stage_decide_reservation(uuid,boolean,text), public.stage_list_reservations(),
  public.stage_reservation_responsibles(uuid) from public, anon, authenticated;
grant execute on function stage_operations.create_reservation(uuid,uuid,timestamptz,timestamptz,jsonb,text),
  stage_operations.decide_reservation(uuid,boolean,text),
  public.stage_create_reservation(uuid,uuid,timestamptz,timestamptz,jsonb,text),
  public.stage_decide_reservation(uuid,boolean,text), public.stage_list_reservations(),
  public.stage_reservation_responsibles(uuid), stage_operations.list_reservations(),
  stage_operations.reservation_responsibles(uuid) to authenticated;

commit;
