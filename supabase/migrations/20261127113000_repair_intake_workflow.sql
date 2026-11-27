begin;

create function public.stage_list_repairs()
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
  if not public.has_permission('repairs.view') then raise insufficient_privilege; end if;
  return jsonb_build_object(
    'can_report',public.has_permission('repairs.create'),
    'can_manage',public.has_permission('repairs.manage'),
    'repairs',coalesce((
      select jsonb_agg(to_jsonb(r) order by r.created_at desc) from (
        select r.id,r.status,r.deadline_at,r.executor_name,r.damage_description,r.repair_description,
          r.created_at,a.name asset,a.inventory_number,s.name project,p.full_name responsible
        from public.repairs r join public.assets a on a.id=r.asset_id
        join public.profiles p on p.id=r.responsible_id
        left join public.shows s on s.id=r.responsible_show_id
        where stage_operations.reservation_asset_visible(a.show_id,a.warehouse_id,a.is_marketing_asset)
          and (r.responsible_show_id is null or public.has_show_access(r.responsible_show_id))
        order by r.created_at desc,r.id limit 100
      ) r
    ),'[]'::jsonb));
end;
$$;

create function public.stage_report_repair(p_asset uuid,p_damage text,p_deadline timestamptz,p_project uuid)
returns uuid language plpgsql security definer set search_path='' as $$
declare asset public.assets%rowtype; repair_id uuid;
begin
  if not (public.has_permission('repairs.view') and public.has_permission('repairs.create')) then
    raise insufficient_privilege;
  end if;
  if coalesce(length(btrim(p_damage)),0) not between 1 and 4000
    or p_deadline is null or not isfinite(p_deadline) or p_deadline<=now() then raise invalid_parameter_value; end if;
  select * into asset from public.assets where id=p_asset for update;
  if not found or asset.is_archived
    or not stage_operations.reservation_asset_visible(asset.show_id,asset.warehouse_id,asset.is_marketing_asset)
    or (asset.physical_show_id is not null and not public.has_show_access(asset.physical_show_id)) then
    raise insufficient_privilege;
  end if;
  if p_project is not null and not public.has_show_access(p_project) then raise insufficient_privilege; end if;
  if exists(select 1 from public.repairs where asset_id=p_asset
      and status in('reported','scheduled','in_progress','awaiting_inspection')) then
    raise exception 'Для цього майна вже є активний ремонт' using errcode='23505';
  end if;
  insert into public.repairs(asset_id,responsible_show_id,reported_by,responsible_id,damage_description,deadline_at)
  values(asset.id,p_project,auth.uid(),auth.uid(),btrim(p_damage),p_deadline)
  returning id into repair_id;
  insert into public.audit_log(actor_id,action_type,entity_type,entity_id,asset_id,show_id,warehouse_id,description)
  values(auth.uid(),'repair_reported','repair',repair_id,asset.id,asset.show_id,asset.warehouse_id,'Заявка на ремонт');
  return repair_id;
end;
$$;

create function public.stage_advance_repair(p_repair uuid,p_status text,p_executor text default null,p_work text default null)
returns void language plpgsql security definer set search_path='' as $$
declare entry public.repairs%rowtype; asset public.assets%rowtype;
begin
  if not (public.has_permission('repairs.view') and public.has_permission('repairs.manage')) then
    raise insufficient_privilege;
  end if;
  select * into entry from public.repairs where id=p_repair for update;
  if not found then raise insufficient_privilege; end if;
  select * into asset from public.assets where id=entry.asset_id;
  if not found or asset.is_archived
    or not stage_operations.reservation_asset_visible(asset.show_id,asset.warehouse_id,asset.is_marketing_asset)
    or (entry.responsible_show_id is not null and not public.has_show_access(entry.responsible_show_id)) then
    raise insufficient_privilege;
  end if;
  if p_status is null or not (
    (entry.status='reported' and p_status='scheduled' and coalesce(length(btrim(p_executor)),0) between 1 and 160)
    or (entry.status='scheduled' and p_status='in_progress')
    or (entry.status='in_progress' and p_status='awaiting_inspection' and coalesce(length(btrim(p_work)),0) between 1 and 4000)
  ) then raise exception 'Цей перехід ремонту недоступний' using errcode='22023'; end if;
  update public.repairs set status=p_status,
    executor_name=case when p_status='scheduled' then btrim(p_executor) else executor_name end,
    started_at=case when p_status='in_progress' then now() else started_at end,
    repair_description=case when p_status='awaiting_inspection' then btrim(p_work) else repair_description end,
    updated_at=now()
  where id=p_repair;
  insert into public.audit_log(actor_id,action_type,entity_type,entity_id,asset_id,show_id,warehouse_id,description)
  values(auth.uid(),'repair_status_changed','repair',p_repair,asset.id,asset.show_id,asset.warehouse_id,p_status);
end;
$$;

revoke execute on function public.stage_list_repairs(),public.stage_report_repair(uuid,text,timestamptz,uuid),
  public.stage_advance_repair(uuid,text,text,text) from public,anon,authenticated;
grant execute on function public.stage_list_repairs(),public.stage_report_repair(uuid,text,timestamptz,uuid),
  public.stage_advance_repair(uuid,text,text,text) to authenticated;
commit;
