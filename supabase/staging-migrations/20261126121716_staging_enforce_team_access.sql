begin;
create or replace function public.stage_team_limits(p_user uuid,p_limits jsonb default null)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare s uuid[]; w uuid[]; before_update jsonb;
begin
  perform pg_catalog.pg_advisory_xact_lock(708217955);
  if not (public.stage_team_capabilities()->>'delegate')::boolean or p_user=auth.uid()
    or not exists(select 1 from public.profiles p join public.roles r on r.id=p.role_id where p.id=p_user and r.code<>'executive_producer') then
    raise insufficient_privilege;
  end if;
  select to_jsonb(l) into before_update from public.stage_member_limits l where l.user_id=p_user;
  if p_limits is not null then
    if jsonb_typeof(p_limits)<>'object' then raise invalid_parameter_value; end if;
    if jsonb_typeof(p_limits->'show_ids')='array' then
      s:=array(select v::uuid from jsonb_array_elements_text(p_limits->'show_ids') v);
    end if;
    if jsonb_typeof(p_limits->'warehouse_ids')='array' then
      w:=array(select v::uuid from jsonb_array_elements_text(p_limits->'warehouse_ids') v);
    end if;
    if exists(select 1 from unnest(s) v where v is null or not exists(select 1 from public.shows where id=v))
      or exists(select 1 from unnest(w) v where v is null or not exists(select 1 from public.warehouses where id=v)) then
      raise invalid_parameter_value;
    end if;
    insert into public.stage_member_limits(user_id,show_ids,warehouse_ids,tasks_read,tasks_write,assets_read)
      values(p_user,s,w,(p_limits->>'tasks_read')::boolean,(p_limits->>'tasks_write')::boolean,(p_limits->>'assets_read')::boolean)
      on conflict(user_id) do update set show_ids=excluded.show_ids,warehouse_ids=excluded.warehouse_ids,
        tasks_read=excluded.tasks_read,tasks_write=excluded.tasks_write,assets_read=excluded.assets_read;
    insert into public.stage_team_audit(actor,subject,action,changes) values(auth.uid(),p_user,'access.updated',
      jsonb_build_object('before',before_update,'after',p_limits));
  end if;
  return jsonb_build_object(
    'limits',(select to_jsonb(l) from public.stage_member_limits l where l.user_id=p_user),
    'shows',(select coalesce(jsonb_agg(to_jsonb(show_row)), '[]') from (select id,name from public.shows order by name) show_row),
    'warehouses',(select coalesce(jsonb_agg(to_jsonb(warehouse_row)), '[]') from (select id,name from public.warehouses order by name) warehouse_row));
end;
$$;


create function public.stage_guard_limited_task_write()
returns trigger language plpgsql security definer set search_path=''
as $$
begin
  if auth.uid() is not null and not public.stage_within_limits('tasks.write',new.show_id,null) then
    raise insufficient_privilege;
  end if;
  if (tg_op='INSERT' or new.owner_id is distinct from old.owner_id)
    and exists (select 1 from public.stage_member_limits l where l.user_id=new.owner_id and (
      not l.tasks_read or (new.show_id is not null and l.show_ids is not null and not(new.show_id=any(l.show_ids)))
    )) then
    raise exception 'Виконавець не має доступу до завдання' using errcode='42501';
  end if;
  return new;
end;
$$;
revoke execute on function public.stage_guard_limited_task_write() from public,anon,authenticated;
create trigger stage_guard_limited_task_write before insert or update on public.stage_tasks
for each row execute function public.stage_guard_limited_task_write();
commit;
