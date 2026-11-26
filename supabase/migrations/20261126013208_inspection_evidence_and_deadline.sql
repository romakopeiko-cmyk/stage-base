begin;

create function stage_private.finish_inspection(
  target_asset uuid, result_condition text, is_complete boolean, note text, checklist jsonb
)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  item public.assets%rowtype;
  check_record public.inspections%rowtype;
  evidence uuid;
  expected_count integer;
  recorded_count integer;
  final_condition text;
begin
  if actor is null or not public.has_permission('inspections.perform') or not exists (
    select 1 from public.profiles p join public.roles r on r.id = p.role_id
    where p.id = actor and p.is_active
      and r.code in ('executive_producer','creative_producer','warehouse_manager','line_producer')
  ) then
    raise exception 'Недостатньо прав' using errcode = '42501';
  end if;

  if result_condition is null or result_condition not in ('good','damaged','unusable')
      or is_complete is null or jsonb_typeof(checklist) is distinct from 'array' then
    raise exception 'Некоректний стан або комплектність';
  end if;

  select * into item from public.assets where id = target_asset for update;
  if not found or item.is_archived or item.location_type <> 'warehouse'
      or not public.has_show_access(item.show_id) or not public.has_warehouse_access(item.warehouse_id)
      or (item.is_marketing_asset and not public.has_permission('assets.marketing')) then
    raise exception 'Майно недоступне';
  end if;

  select * into check_record from public.inspections where asset_id = target_asset
    and status in ('pending','in_progress') order by received_at desc, id desc limit 1 for update;
  if not found then
    raise exception 'Немає відкритої перевірки';
  end if;

  select p.id into evidence from public.asset_photos p
  join storage.objects o on o.bucket_id = 'asset-photos' and o.name = p.storage_path
  where p.asset_id = target_asset and p.uploaded_by = actor
    and p.created_at >= check_record.received_at and o.created_at >= check_record.received_at
  order by p.created_at desc, p.id desc limit 1;
  if not found then
    raise exception 'Спочатку завантажте актуальне фото';
  end if;

  if item.tracking_type = 'set' then
    -- Prevent concurrent component updates and inserts while capturing the checklist.
    perform c.id from public.asset_components c where c.asset_id = target_asset order by c.id for update;
    select count(*) into expected_count from public.asset_components where asset_id = target_asset;
    if expected_count = 0 or jsonb_array_length(checklist) <> expected_count then
      raise exception 'Заповніть чекліст усіх складових комплекту';
    end if;

    insert into public.inspection_components(
      inspection_id, component_id, expected_quantity, actual_quantity, condition_result, comment
    )
    select check_record.id, c.id, c.quantity, input.quantity, input.condition, nullif(btrim(input.comment), '')
    from jsonb_to_recordset(checklist) input(id uuid, quantity integer, condition text, comment text)
    join public.asset_components c on c.id = input.id and c.asset_id = target_asset
    where input.quantity >= 0 and input.condition in ('good','damaged','unusable')
    group by c.id, c.quantity, input.quantity, input.condition, input.comment
    having count(*) = 1 and (
      select count(*) from jsonb_to_recordset(checklist) ids(id uuid) where ids.id = c.id
    ) = 1;
    get diagnostics recorded_count = row_count;
    if recorded_count <> expected_count then
      raise exception 'Кожна складова потребує одного запису з кількістю та станом';
    end if;

    select bool_and(actual_quantity = expected_quantity) into is_complete
    from public.inspection_components where inspection_id = check_record.id;
    if result_condition = 'good' and exists (
      select 1 from public.inspection_components
      where inspection_id = check_record.id and condition_result <> 'good'
    ) then
      result_condition := 'damaged';
    end if;
  elsif jsonb_array_length(checklist) <> 0 then
    raise exception 'Чекліст доступний для комплектів';
  end if;

  final_condition := case when not is_complete and result_condition = 'good' then 'damaged' else result_condition end;
  insert into public.inspection_photos(inspection_id, photo_id) values (check_record.id, evidence);

  update public.inspections set status = 'completed', condition_result = final_condition,
    completeness_confirmed = is_complete, inspected_by = actor, inspected_at = now(),
    comment = note, updated_at = now()
  where id = check_record.id;

  update public.assets set condition = final_condition,
    completeness = case when is_complete then 'Комплектний' else 'Неповний' end,
    last_inspected_at = now(), inspection_due_at = null
  where id = target_asset;
end;
$$;

create or replace function stage_private.complete_inspection(
  p_asset uuid, p_condition text, p_complete boolean, p_comment text
)
returns void
language sql security definer
set search_path = ''
as $$ select stage_private.finish_inspection(p_asset, p_condition, p_complete, p_comment, '[]'::jsonb); $$;

create function stage_private.change_inspection_deadline(target_asset uuid, new_deadline timestamptz, reason text)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  item public.assets%rowtype;
  check_record public.inspections%rowtype;
begin
  if actor is null or not public.has_permission('inspections.deadline') or not exists (
    select 1 from public.profiles p join public.roles r on r.id = p.role_id
    where p.id = actor and p.is_active and r.code = 'executive_producer'
  ) then
    raise exception 'Змінити строк може виконавчий продюсер' using errcode = '42501';
  end if;
  if new_deadline is null or not isfinite(new_deadline) or nullif(btrim(reason), '') is null then
    raise exception 'Вкажіть строк та причину';
  end if;

  select * into item from public.assets where id = target_asset for update;
  if not found or item.is_archived
      or not public.has_show_access(item.show_id) or not public.has_warehouse_access(item.warehouse_id)
      or (item.is_marketing_asset and not public.has_permission('assets.marketing')) then
    raise exception 'Майно недоступне';
  end if;

  select * into check_record from public.inspections where asset_id = target_asset
    and status in ('pending','in_progress') order by received_at desc, id desc limit 1 for update;
  if not found or new_deadline < check_record.received_at then
    raise exception 'Немає відкритої перевірки або строк раніше приймання';
  end if;

  update public.inspections set deadline_at = new_deadline, deadline_changed_by = actor,
    deadline_change_reason = btrim(reason), updated_at = now()
  where id = check_record.id;

  update public.assets set inspection_due_at = new_deadline where id = target_asset;

  insert into public.audit_log(actor_id, action_type, entity_type, entity_id, asset_id, show_id, warehouse_id, description)
  values (actor, 'inspection_deadline_changed', 'inspection', check_record.id, target_asset,
    item.show_id, item.warehouse_id, 'Змінено строк перевірки: ' || btrim(reason));
end;
$$;

create function public.stage_finish_inspection(
  p_asset uuid, p_condition text, p_complete boolean, p_comment text, p_checklist jsonb
)
returns void language sql security invoker set search_path = ''
as $$ select stage_private.finish_inspection(p_asset,p_condition,p_complete,p_comment,p_checklist); $$;

create function public.stage_change_inspection_deadline(p_asset uuid, p_deadline timestamptz, p_reason text)
returns void language sql security invoker set search_path = ''
as $$ select stage_private.change_inspection_deadline(p_asset,p_deadline,p_reason); $$;

revoke execute on function stage_private.finish_inspection(uuid,text,boolean,text,jsonb),
  stage_private.change_inspection_deadline(uuid,timestamptz,text),
  public.stage_finish_inspection(uuid,text,boolean,text,jsonb),
  public.stage_change_inspection_deadline(uuid,timestamptz,text) from public, anon, authenticated;
grant execute on function stage_private.finish_inspection(uuid,text,boolean,text,jsonb),
  stage_private.change_inspection_deadline(uuid,timestamptz,text),
  public.stage_finish_inspection(uuid,text,boolean,text,jsonb),
  public.stage_change_inspection_deadline(uuid,timestamptz,text) to authenticated;

commit;
