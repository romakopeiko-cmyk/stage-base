begin;

alter table public.assets add column physical_show_id uuid references public.shows(id);

create table stage_operations.stock_custody (
  issue_item_id uuid primary key references public.movement_items(id),
  reservation_id uuid not null references public.reservations(id),
  asset_id uuid not null references public.assets(id),
  recipient_id uuid not null references public.profiles(id),
  issued_quantity numeric not null check (issued_quantity > 0),
  outstanding numeric not null check (outstanding >= 0 and outstanding <= issued_quantity),
  confirmed_at timestamptz,
  unique(reservation_id, asset_id)
);
alter table stage_operations.stock_custody enable row level security;
revoke all on stage_operations.stock_custody from public, anon, authenticated;
create index stage_outstanding_asset_idx on stage_operations.stock_custody(asset_id) where outstanding > 0;
create index stage_custody_recipient_idx on stage_operations.stock_custody(recipient_id);

-- Receipt confirmation is independent of a later physical return.
create or replace function stage_operations.guard_issue()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  target uuid;
  movement_kind text;
begin
  if tg_table_name = 'movement_items' then
    select movement_type into movement_kind from public.movements where id=new.movement_id for update;
    if movement_kind='issue' then
      perform stage_operations.assert_issue_inspected(new.asset_id,new.movement_id);
    end if;
  elsif new.movement_type='issue' and (
    old.movement_type is distinct from new.movement_type
    or old.dispatched_at is distinct from new.dispatched_at
    or (new.status='in_transit' and old.status is distinct from new.status)
  ) then
    for target in select distinct asset_id from public.movement_items where movement_id=new.id order by asset_id
    loop
      perform stage_operations.assert_issue_inspected(target,new.id);
    end loop;
  end if;
  return new;
end;
$$;

create function stage_operations.stock_clerk(permission_code text)
returns boolean language sql stable security invoker set search_path = ''
as $$
 select public.has_permission(permission_code) and exists (
   select 1 from public.profiles p join public.roles r on r.id=p.role_id
   where p.id=auth.uid() and p.is_active and r.code='warehouse_manager'
 );
$$;

create function stage_operations.stock_issue(request_id uuid, scanned jsonb)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare
  request public.reservations%rowtype;
  asset public.assets%rowtype;
  line record;
  movement uuid;
  movement_item uuid;
  total integer;
begin
  if not stage_operations.stock_clerk('movements.issue') then
    raise exception 'Видача доступна комірнику' using errcode='42501';
  end if;
  select * into request from public.reservations where id=request_id for update;
  if not found or not public.has_show_access(request.show_id) then
    raise exception 'Бронювання недоступне';
  end if;
  if request.status='issued' then
    select id into movement from public.movements
    where reservation_id=request_id and movement_type='issue' order by created_at desc limit 1;
    return movement;
  end if;
  if request.status<>'approved' or request.end_date<=now() or not exists (
    select 1 from public.profiles where id=request.responsible_id and is_active
  ) then
    raise exception 'Потрібне чинне погодження та активний отримувач';
  end if;
  select count(*) into total from public.reservation_items where reservation_id=request_id;
  if jsonb_typeof(scanned) is distinct from 'object' or total=0
      or (select count(*) from jsonb_object_keys(scanned))<>total then
    raise exception 'Зчитайте QR кожної позиції';
  end if;

  insert into public.movements(reservation_id,movement_type,to_show_id,created_by,handed_over_by,
    received_by,status,approved_by,approved_at,dispatched_at)
  values(request_id,'issue',request.show_id,auth.uid(),auth.uid(),request.responsible_id,
    'in_transit',request.approved_by,request.approved_at,now()) returning id into movement;

  for line in select asset_id,quantity from public.reservation_items
    where reservation_id=request_id order by asset_id
  loop
    select * into asset from public.assets where id=line.asset_id for update;
    if not found or asset.is_archived or asset.location_type<>'warehouse'
        or not stage_operations.reservation_asset_visible(asset.show_id,asset.warehouse_id,asset.is_marketing_asset)
        or asset.condition not in ('excellent','good','fair','unverified')
        or (scanned->>asset.id::text) is distinct from asset.qr_code then
      raise exception 'Позиція недоступна або QR не відповідає картці';
    end if;
    if line.quantity > asset.quantity - coalesce((
      select sum(outstanding) from stage_operations.stock_custody where asset_id=asset.id
    ),0) then
      raise exception 'Недостатньо фізичного залишку на складі';
    end if;
    insert into public.movement_items(movement_id,asset_id,quantity,condition_before)
      values(movement,asset.id,line.quantity,asset.condition) returning id into movement_item;
    insert into stage_operations.stock_custody(issue_item_id,reservation_id,asset_id,recipient_id,issued_quantity,outstanding)
      values(movement_item,request_id,asset.id,request.responsible_id,line.quantity,line.quantity);
    if asset.tracking_type<>'consumable' then
      update public.assets set location_type='project',physical_show_id=request.show_id,
        responsible_id=request.responsible_id,last_used_at=now() where id=asset.id;
    else
      update public.assets set last_used_at=now() where id=asset.id;
    end if;
    insert into public.audit_log(actor_id,action_type,entity_type,entity_id,asset_id,show_id,warehouse_id,description)
      values(auth.uid(),'asset_issued','movement',movement,asset.id,request.show_id,asset.warehouse_id,'Видано за погодженим бронюванням');
  end loop;
  update public.reservations set status='issued',updated_at=now() where id=request_id;
  insert into public.notifications(recipient_id,notification_type,title,message,entity_type,entity_id)
    values(request.responsible_id,'asset_issued','Підтвердіть отримання','Майно видано. Підтвердьте отримання в розділі операцій.','movement',movement);
  return movement;
end;
$$;

create function stage_operations.stock_confirm(issue_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  dispatch public.movements%rowtype;
begin
  if auth.uid() is null or not exists (select 1 from public.profiles where id=auth.uid() and is_active) then
    raise exception 'Недостатньо прав' using errcode='42501';
  end if;
  select * into dispatch from public.movements where id=issue_id for update;
  if not found or dispatch.movement_type<>'issue' or dispatch.received_by is distinct from auth.uid()
      or not exists (select 1 from stage_operations.stock_custody c
        join public.movement_items i on i.id=c.issue_item_id where i.movement_id=issue_id) then
    raise exception 'Видача недоступна' using errcode='42501';
  end if;
  if dispatch.received_at is not null then return; end if;
  update stage_operations.stock_custody c set confirmed_at=now()
    from public.movement_items i where i.id=c.issue_item_id and i.movement_id=issue_id;
  update public.movements set status='received',received_at=now(),updated_at=now() where id=issue_id;
  insert into public.audit_log(actor_id,action_type,entity_type,entity_id,show_id,description)
    values(auth.uid(),'receipt_confirmed','movement',issue_id,dispatch.to_show_id,'Отримувач підтвердив видачу');
end;
$$;

create function stage_operations.stock_return(
  issue_line uuid, target_warehouse uuid, returned numeric, consumed numeric, request_key uuid
)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare
  custody stage_operations.stock_custody%rowtype;
  asset public.assets%rowtype;
  movement uuid;
  movement_item uuid;
  existing_inspection uuid;
  deadline timestamptz;
  source_show uuid;
begin
  if not stage_operations.stock_clerk('movements.return') or not public.has_warehouse_access(target_warehouse) then
    raise exception 'Приймання доступне уповноваженому комірнику' using errcode='42501';
  end if;
  if request_key is null or returned is null or consumed is null
      or returned::text in ('NaN','Infinity','-Infinity') or consumed::text in ('NaN','Infinity','-Infinity')
      or returned<0 or consumed<0 or returned+consumed<=0
      or not exists (select 1 from public.warehouses where id=target_warehouse and is_active) then
    raise exception 'Перевірте склад, кількість повернення та використання';
  end if;
  select * into custody from stage_operations.stock_custody where issue_item_id=issue_line for update;
  if not found then raise exception 'Позицію видачі не знайдено'; end if;
  select show_id into source_show from public.reservations where id=custody.reservation_id for update;
  if not public.has_show_access(source_show) then raise exception 'Шоу недоступне'; end if;
  select * into asset from public.assets where id=custody.asset_id for update;
  if not found or not stage_operations.reservation_asset_visible(asset.show_id,asset.warehouse_id,asset.is_marketing_asset) then
    raise exception 'Майно недоступне';
  end if;
  select m.id into movement from public.movements m join public.movement_items i on i.movement_id=m.id
    where m.id=request_key and m.reservation_id=custody.reservation_id and m.movement_type='return'
      and m.created_by=auth.uid() and m.to_warehouse_id=target_warehouse and i.asset_id=asset.id
      and i.comment=format('Повернуто: %s. Використано: %s.',returned,consumed);
  if found then return movement; end if;
  if returned+consumed>custody.outstanding
      or (asset.tracking_type<>'consumable' and (consumed<>0 or returned<>1))
      or (asset.tracking_type='consumable' and (consumed>asset.quantity or target_warehouse is distinct from asset.warehouse_id)) then
    raise exception 'Перевірте залишок, тип і склад повернення';
  end if;

  insert into public.movements(id,reservation_id,movement_type,from_show_id,to_warehouse_id,created_by,
    handed_over_by,received_by,status,received_at,completed_at)
    values(request_key,custody.reservation_id,'return',source_show,target_warehouse,auth.uid(),
    custody.recipient_id,auth.uid(),'completed',now(),now()) returning id into movement;
  insert into public.movement_items(movement_id,asset_id,quantity,condition_before,comment)
    values(movement,asset.id,returned+consumed,asset.condition,
    format('Повернуто: %s. Використано: %s.',returned,consumed)) returning id into movement_item;
  update stage_operations.stock_custody set outstanding=outstanding-returned-consumed where issue_item_id=issue_line;

  if returned>0 then
    select id,deadline_at into existing_inspection,deadline from public.inspections
      where asset_id=asset.id and status in ('pending','in_progress')
      order by received_at desc,id desc limit 1 for update;
    if existing_inspection is null then
      deadline:=((now() at time zone 'Europe/Kyiv')+interval '7 days') at time zone 'Europe/Kyiv';
      insert into public.inspections(asset_id,movement_item_id,assigned_to,inspection_type,received_at,deadline_at)
        values(asset.id,movement_item,auth.uid(),'return',now(),deadline);
    else
      update public.inspections set received_at=now(),movement_item_id=movement_item,updated_at=now(),
        emergency_release_by=null, emergency_release_at=null, emergency_release_reason=null
        where id=existing_inspection;
    end if;
    update public.assets set quantity=quantity-consumed,condition='unverified',warehouse_id=target_warehouse,
      physical_show_id=null,location_type='warehouse',responsible_id=auth.uid(),inspection_due_at=deadline where id=asset.id;
  else
    update public.assets set quantity=quantity-consumed where id=asset.id;
  end if;
  if not exists (select 1 from stage_operations.stock_custody where reservation_id=custody.reservation_id and outstanding>0) then
    update public.reservations set status='completed',updated_at=now() where id=custody.reservation_id;
  end if;
  insert into public.audit_log(actor_id,action_type,entity_type,entity_id,asset_id,show_id,warehouse_id,description)
    values(auth.uid(),'asset_returned','movement',movement,asset.id,source_show,target_warehouse,'Зафіксовано повернення або використання');
  return movement;
end;
$$;

create function stage_operations.stock_transfer(target_asset uuid, destination uuid, scanned text, request_key uuid)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare
  item public.assets%rowtype;
begin
  if not stage_operations.stock_clerk('movements.transfer') or not public.has_warehouse_access(destination) then
    raise exception 'Переміщення доступне уповноваженому комірнику' using errcode='42501';
  end if;
  if request_key is null or not exists (select 1 from public.warehouses where id=destination and is_active) then
    raise exception 'Потрібен підтверджений склад призначення';
  end if;
  select * into item from public.assets where id=target_asset for update;
  if not found or not stage_operations.reservation_asset_visible(item.show_id,item.warehouse_id,item.is_marketing_asset) then
    raise exception 'Майно недоступне';
  end if;
  if exists (select 1 from public.movements m join public.movement_items i on i.movement_id=m.id
    where m.id=request_key and m.movement_type='transfer' and m.created_by=auth.uid()
    and m.to_warehouse_id=destination and i.asset_id=target_asset) then
    return request_key;
  end if;
  if item.is_archived or item.location_type<>'warehouse' or item.warehouse_id is null
      or item.warehouse_id=destination or item.quantity<=0 or item.qr_code is distinct from scanned
      or exists (select 1 from stage_operations.stock_custody where asset_id=item.id and outstanding>0) then
    raise exception 'Перевірте QR, вихідне місце, залишок і склад призначення';
  end if;
  insert into public.movements(id,movement_type,from_warehouse_id,to_warehouse_id,created_by,
    received_by,status,received_at,completed_at)
    values(request_key,'transfer',item.warehouse_id,destination,auth.uid(),auth.uid(),'completed',now(),now());
  insert into public.movement_items(movement_id,asset_id,quantity,condition_before)
    values(request_key,item.id,item.quantity,item.condition);
  update public.assets set warehouse_id=destination,responsible_id=auth.uid() where id=item.id;
  insert into public.audit_log(actor_id,action_type,entity_type,entity_id,asset_id,show_id,warehouse_id,description)
    values(auth.uid(),'asset_transferred','movement',request_key,item.id,item.show_id,destination,'Підтверджено переміщення між складами');
  return request_key;
end;
$$;

create function stage_operations.list_stock()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  can_issue boolean := stage_operations.stock_clerk('movements.issue');
  can_return boolean := stage_operations.stock_clerk('movements.return');
  can_transfer boolean := stage_operations.stock_clerk('movements.transfer');
begin
  if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and is_active) then
    raise exception 'Недостатньо прав' using errcode='42501';
  end if;
  return jsonb_build_object(
    'can_transfer',can_transfer,
    'approved',coalesce((
      select jsonb_agg(to_jsonb(q) order by q.end_date,q.id) from (
        select r.id,s.name as show,p.full_name as recipient,r.end_date,(
          select jsonb_agg(jsonb_build_object('id',a.id,'name',a.name,'number',a.inventory_number,'quantity',i.quantity)
            order by a.name,a.id)
          from public.reservation_items i join public.assets a on a.id=i.asset_id where i.reservation_id=r.id
        ) as items
        from public.reservations r join public.shows s on s.id=r.show_id join public.profiles p on p.id=r.responsible_id
        where can_issue and r.status='approved' and r.end_date>now() and public.has_show_access(r.show_id)
          and not exists (
            select 1 from public.reservation_items i join public.assets a on a.id=i.asset_id where i.reservation_id=r.id
              and not stage_operations.reservation_asset_visible(a.show_id,a.warehouse_id,a.is_marketing_asset)
          )
        order by r.end_date,r.id limit 100
      ) q
    ),'[]'::jsonb),
    'outstanding',coalesce((
      select jsonb_agg(to_jsonb(q) order by q.issue_id,q.item_id) from (
        select c.issue_item_id as item_id,m.id as issue_id,a.name,a.inventory_number,c.outstanding,c.confirmed_at,
          a.tracking_type,a.unit,p.full_name as recipient,
          c.recipient_id=auth.uid() and c.confirmed_at is null as can_confirm,
          can_return and c.outstanding>0 and public.has_show_access(m.to_show_id)
            and stage_operations.reservation_asset_visible(a.show_id,a.warehouse_id,a.is_marketing_asset) as can_return
        from stage_operations.stock_custody c join public.movement_items i on i.id=c.issue_item_id
        join public.movements m on m.id=i.movement_id join public.assets a on a.id=c.asset_id
        join public.profiles p on p.id=c.recipient_id
        where (c.recipient_id=auth.uid() and c.confirmed_at is null)
          or (can_return and c.outstanding>0 and public.has_show_access(m.to_show_id)
            and stage_operations.reservation_asset_visible(a.show_id,a.warehouse_id,a.is_marketing_asset))
        order by m.id,c.issue_item_id limit 200
      ) q
    ),'[]'::jsonb)
  );
end;
$$;

grant select(physical_show_id) on public.assets to authenticated;

create function public.stage_stock_issue(p_reservation uuid,p_scanned jsonb)
returns uuid language sql security invoker set search_path=''
as $$ select stage_operations.stock_issue(p_reservation,p_scanned); $$;
create function public.stage_stock_confirm(p_issue uuid)
returns void language sql security invoker set search_path=''
as $$ select stage_operations.stock_confirm(p_issue); $$;
create function public.stage_stock_return(p_item uuid,p_warehouse uuid,p_returned numeric,p_consumed numeric,p_key uuid)
returns uuid language sql security invoker set search_path=''
as $$ select stage_operations.stock_return(p_item,p_warehouse,p_returned,p_consumed,p_key); $$;
create function public.stage_stock_transfer(p_asset uuid,p_warehouse uuid,p_scanned text,p_key uuid)
returns uuid language sql security invoker set search_path=''
as $$ select stage_operations.stock_transfer(p_asset,p_warehouse,p_scanned,p_key); $$;
create function public.stage_list_stock()
returns jsonb language sql stable security invoker set search_path=''
as $$ select stage_operations.list_stock(); $$;

revoke execute on function stage_operations.stock_clerk(text),stage_operations.stock_issue(uuid,jsonb),
 stage_operations.stock_confirm(uuid),stage_operations.stock_return(uuid,uuid,numeric,numeric,uuid),
 stage_operations.stock_transfer(uuid,uuid,text,uuid),stage_operations.list_stock(),
 public.stage_stock_issue(uuid,jsonb),public.stage_stock_confirm(uuid),public.stage_stock_return(uuid,uuid,numeric,numeric,uuid),
 public.stage_stock_transfer(uuid,uuid,text,uuid),public.stage_list_stock() from public,anon,authenticated;
grant execute on function stage_operations.stock_issue(uuid,jsonb),
 stage_operations.stock_confirm(uuid),stage_operations.stock_return(uuid,uuid,numeric,numeric,uuid),
 stage_operations.stock_transfer(uuid,uuid,text,uuid),stage_operations.list_stock(),
 public.stage_stock_issue(uuid,jsonb),public.stage_stock_confirm(uuid),public.stage_stock_return(uuid,uuid,numeric,numeric,uuid),
 public.stage_stock_transfer(uuid,uuid,text,uuid),public.stage_list_stock() to authenticated;

alter table public.stage_tasks
  add column inspection_id uuid unique references public.inspections(id),
  add column inspection_asset_id uuid references public.assets(id);

drop policy stage_tasks_owner_update on public.stage_tasks;
create policy stage_tasks_owner_update on public.stage_tasks for update to authenticated
  using (inspection_id is null and owner_id=(select auth.uid()) and exists (
    select 1 from public.profiles where id=(select auth.uid()) and is_active
  ))
  with check (inspection_id is null and owner_id=(select auth.uid()) and exists (
    select 1 from public.profiles where id=(select auth.uid()) and is_active
  ));

create function stage_operations.sync_return_check_task()
returns trigger language plpgsql security definer set search_path=''
as $$
declare
  asset_name text;
begin
  if new.inspection_type <> 'return' or new.assigned_to is null then return new; end if;
  select name into asset_name from public.assets where id=new.asset_id;
  insert into public.stage_tasks(owner_id,title,priority,status,due_at,inspection_id,inspection_asset_id)
  values(new.assigned_to,left('Перевірити повернене майно: '||asset_name,180),'high','todo',
    new.deadline_at,new.id,new.asset_id)
  on conflict (inspection_id) do update set
    owner_id=excluded.owner_id,
    due_at=excluded.due_at,
    status=case new.status when 'completed' then 'done' when 'in_progress' then 'doing' else 'todo' end;
  return new;
end;
$$;
revoke execute on function stage_operations.sync_return_check_task() from public,anon,authenticated;

create trigger stage_sync_return_check_task
after insert or update of status,deadline_at,assigned_to on public.inspections
for each row execute function stage_operations.sync_return_check_task();

commit;
