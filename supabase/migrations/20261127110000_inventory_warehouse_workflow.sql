begin;

create function public.stage_warehouse_inventory(p_session uuid default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
  if not public.has_permission('inventory.view') then raise insufficient_privilege; end if;
  return jsonb_build_object(
    'can_create',public.has_permission('inventory.create'),
    'can_count',public.has_permission('inventory.perform'),
    'can_complete',public.has_permission('inventory.complete'),
    'sessions',coalesce((
      select jsonb_agg(to_jsonb(s) order by s.created_at desc) from (
        select s.id,s.name,s.status,s.created_at,w.name warehouse
        from public.inventory_sessions s join public.warehouses w on w.id=s.warehouse_id
        where s.show_id is null and public.has_warehouse_access(w.id)
          and (p_session is null or s.id=p_session)
        order by s.created_at desc limit 100
      ) s
    ),'[]'::jsonb),
    'items',coalesce((
      select jsonb_agg(jsonb_build_object('id',i.id,'name',a.name,'number',a.inventory_number,
        'expected',i.expected_quantity,'actual',i.actual_quantity,'status',i.status) order by a.name,i.id)
      from public.inventory_items i join public.inventory_sessions s on s.id=i.session_id
      join public.assets a on a.id=i.asset_id
      where s.id=p_session and s.show_id is null and public.has_warehouse_access(s.warehouse_id)
        and stage_operations.reservation_asset_visible(a.show_id,a.warehouse_id,a.is_marketing_asset)
    ),'[]'::jsonb));
end;
$$;

create function public.stage_start_warehouse_inventory(p_warehouse uuid,p_name text)
returns uuid language plpgsql security definer set search_path='' as $$
declare session_id uuid;
begin
  if not (public.has_permission('inventory.view') and public.has_permission('inventory.create'))
    or p_warehouse is null or not public.has_warehouse_access(p_warehouse) then raise insufficient_privilege; end if;
  if coalesce(length(btrim(p_name)),0) not between 1 and 120 then raise invalid_parameter_value; end if;
  insert into public.inventory_sessions(name,inventory_type,warehouse_id,created_by,responsible_id,status,started_at)
  values(btrim(p_name),'partial',p_warehouse,auth.uid(),auth.uid(),'in_progress',now()) returning id into session_id;
  insert into public.inventory_items(session_id,asset_id,expected_quantity)
    select session_id,a.id,a.quantity from public.assets a
    where a.warehouse_id=p_warehouse and a.location_type='warehouse' and not a.is_archived
      and stage_operations.reservation_asset_visible(a.show_id,a.warehouse_id,a.is_marketing_asset);
  if not found then raise exception 'На складі немає доступного майна для обліку' using errcode='22023'; end if;
  return session_id;
end;
$$;

create function public.stage_record_warehouse_count(p_session uuid,p_item uuid,p_qr text,p_actual numeric)
returns void language plpgsql security definer set search_path='' as $$
declare current_session public.inventory_sessions%rowtype;
begin
  if not (public.has_permission('inventory.view') and public.has_permission('inventory.perform')) then raise insufficient_privilege; end if;
  select * into current_session from public.inventory_sessions where id=p_session for update;
  if not found or current_session.show_id is not null or current_session.warehouse_id is null
    or not public.has_warehouse_access(current_session.warehouse_id) then raise insufficient_privilege; end if;
  if current_session.status<>'in_progress' or p_actual is null or p_actual<0 or p_actual>999999999
    or p_actual<>round(p_actual,3) then raise invalid_parameter_value; end if;
  update public.inventory_items i set actual_quantity=p_actual,
    status=case when p_actual=0 then 'missing' when p_actual=i.expected_quantity then 'verified'
      when p_actual>i.expected_quantity then 'surplus' else 'quantity_mismatch' end,
    checked_by=auth.uid(),checked_at=now()
  from public.assets a
  where i.id=p_item and i.session_id=p_session and a.id=i.asset_id
    and stage_operations.reservation_asset_visible(a.show_id,a.warehouse_id,a.is_marketing_asset)
    and (p_actual=0 or a.qr_code=btrim(p_qr));
  if not found then raise exception 'Позиція недоступна або QR не збігається' using errcode='22023'; end if;
end;
$$;

create function public.stage_complete_warehouse_inventory(p_session uuid)
returns void language plpgsql security definer set search_path='' as $$
declare current_session public.inventory_sessions%rowtype;
begin
  if not (public.has_permission('inventory.view') and public.has_permission('inventory.complete')) then raise insufficient_privilege; end if;
  select * into current_session from public.inventory_sessions where id=p_session for update;
  if not found or current_session.show_id is not null or current_session.warehouse_id is null
    or not public.has_warehouse_access(current_session.warehouse_id) then raise insufficient_privilege; end if;
  if current_session.status='completed' then return; end if;
  if current_session.status<>'in_progress' or exists (
    select 1 from public.inventory_items where session_id=p_session and status='pending'
  ) then raise exception 'Спочатку завершіть облік усіх позицій' using errcode='22023'; end if;
  update public.inventory_sessions set status='completed',completed_at=now(),updated_at=now() where id=p_session;
end;
$$;

revoke execute on function public.stage_warehouse_inventory(uuid),public.stage_start_warehouse_inventory(uuid,text),
  public.stage_record_warehouse_count(uuid,uuid,text,numeric),public.stage_complete_warehouse_inventory(uuid)
  from public,anon,authenticated;
grant execute on function public.stage_warehouse_inventory(uuid),public.stage_start_warehouse_inventory(uuid,text),
  public.stage_record_warehouse_count(uuid,uuid,text,numeric),public.stage_complete_warehouse_inventory(uuid)
  to authenticated;
commit;
