begin;

create or replace function public.stage_list_repairs()
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
  if not public.has_permission('repairs.view') then raise insufficient_privilege; end if;
  return jsonb_build_object(
    'can_report',public.has_permission('repairs.create'),
    'can_manage',public.has_permission('repairs.manage'),
    'can_complete',public.has_permission('repairs.complete'),
    'repairs',coalesce((
      select jsonb_agg(to_jsonb(r) order by r.created_at desc) from (
        select r.id,r.asset_id,r.status,r.deadline_at,r.executor_name,r.damage_description,r.repair_description,
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

create or replace function public.stage_advance_repair(p_repair uuid,p_status text,p_executor text default null,p_work text default null)
returns void language plpgsql security definer set search_path='' as $$
declare entry public.repairs%rowtype; asset public.assets%rowtype; inspection uuid;
begin
  if not (public.has_permission('repairs.view') and public.has_permission('repairs.manage')) then
    raise insufficient_privilege;
  end if;
  select * into entry from public.repairs where id=p_repair for update;
  if not found then raise insufficient_privilege; end if;
  select * into asset from public.assets where id=entry.asset_id for update;
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
  if p_status='awaiting_inspection' then
    if asset.location_type<>'warehouse' or asset.warehouse_id is null or exists(
      select 1 from public.inspections where asset_id=asset.id and status in('pending','in_progress')
    ) then raise exception 'Поверніть майно на склад і закрийте попередню перевірку' using errcode='22023'; end if;
    insert into public.inspections(asset_id,inspection_type,received_at,deadline_at)
      values(asset.id,'after_repair',now(),now()+interval '7 days') returning id into inspection;
    update public.assets set condition='unverified',inspection_due_at=now()+interval '7 days' where id=asset.id;
  end if;
  update public.repairs set status=p_status,
    inspection_id=coalesce(inspection,inspection_id),
    executor_name=case when p_status='scheduled' then btrim(p_executor) else executor_name end,
    started_at=case when p_status='in_progress' then now() else started_at end,
    repair_description=case when p_status='awaiting_inspection' then btrim(p_work) else repair_description end,
    updated_at=now()
  where id=p_repair;
  insert into public.audit_log(actor_id,action_type,entity_type,entity_id,asset_id,show_id,warehouse_id,description)
  values(auth.uid(),'repair_status_changed','repair',p_repair,asset.id,asset.show_id,asset.warehouse_id,p_status);
end;
$$;

create function public.stage_complete_repair(p_repair uuid)
returns void language plpgsql security definer set search_path='' as $$
declare entry public.repairs%rowtype; asset public.assets%rowtype; evidence uuid;
begin
  if not (public.has_permission('repairs.view') and public.has_permission('repairs.complete')) then
    raise insufficient_privilege;
  end if;
  select * into entry from public.repairs where id=p_repair for update;
  if not found then raise insufficient_privilege; end if;
  select * into asset from public.assets where id=entry.asset_id for update;
  if not found or asset.is_archived
    or not stage_operations.reservation_asset_visible(asset.show_id,asset.warehouse_id,asset.is_marketing_asset)
    or (entry.responsible_show_id is not null and not public.has_show_access(entry.responsible_show_id)) then
    raise insufficient_privilege;
  end if;
  if entry.status='completed' then return; end if;
  if entry.status<>'awaiting_inspection' or asset.condition<>'good' then
    raise exception 'Потрібна успішна перевірка після ремонту' using errcode='22023';
  end if;
  select p.id into evidence from public.inspections i
  join public.inspection_photos ip on ip.inspection_id=i.id
  join public.asset_photos p on p.id=ip.photo_id and p.asset_id=i.asset_id
  join storage.objects o on o.bucket_id='asset-photos' and o.name=p.storage_path
  where i.id=entry.inspection_id and i.asset_id=asset.id and i.inspection_type='after_repair'
    and i.status='completed' and i.condition_result='good' and i.completeness_confirmed
    and p.created_at>=i.received_at and o.created_at>=i.received_at
  order by p.created_at desc,p.id limit 1;
  if not found then raise exception 'Потрібне актуальне фото перевірки після ремонту' using errcode='22023'; end if;
  insert into public.repair_photos(repair_id,photo_id,photo_type) values(entry.id,evidence,'after')
    on conflict(repair_id,photo_id) do nothing;
  update public.repairs set status='completed',completed_at=now(),updated_at=now() where id=entry.id;
  insert into public.audit_log(actor_id,action_type,entity_type,entity_id,asset_id,show_id,warehouse_id,description)
  values(auth.uid(),'repair_completed','repair',entry.id,asset.id,asset.show_id,asset.warehouse_id,'Ремонт завершено після перевірки');
end;
$$;
revoke execute on function public.stage_complete_repair(uuid) from public,anon,authenticated;
grant execute on function public.stage_complete_repair(uuid) to authenticated;
commit;
