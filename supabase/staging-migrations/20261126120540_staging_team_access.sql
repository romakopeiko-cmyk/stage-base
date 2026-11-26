-- This migration targets the isolated staging schema.
begin;

create table public.stage_member_limits (
  user_id uuid primary key references public.profiles,
  show_ids uuid[],
  warehouse_ids uuid[],
  tasks_read boolean not null default true,
  tasks_write boolean not null default true,
  assets_read boolean not null default true
);
alter table public.stage_member_limits enable row level security;
revoke all on public.stage_member_limits from public,anon,authenticated;

create function public.stage_team_limits(p_user uuid,p_limits jsonb default null)
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
    if exists(select 1 from unnest(s) v where not exists(select 1 from public.shows where id=v))
      or exists(select 1 from unnest(w) v where not exists(select 1 from public.warehouses where id=v)) then
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
    'shows',(select coalesce(jsonb_agg(to_jsonb(s)), '[]') from (select id,name from public.shows order by name) s),
    'warehouses',(select coalesce(jsonb_agg(to_jsonb(w)), '[]') from (select id,name from public.warehouses order by name) w));
end;
$$;

create function public.stage_within_limits(p_feature text,p_show uuid,p_warehouse uuid)
returns boolean language sql stable security definer set search_path=''
as $$
  select public.stage_member_active() and not exists (
    select 1 from public.stage_member_limits l where l.user_id=auth.uid() and (
      (p_feature='tasks.read' and not l.tasks_read)
      or (p_feature='tasks.write' and (not l.tasks_read or not l.tasks_write))
      or (p_feature='assets.read' and not l.assets_read)
      or (p_show is not null and l.show_ids is not null and not (p_show=any(l.show_ids)))
      or (p_warehouse is not null and l.warehouse_ids is not null and not (p_warehouse=any(l.warehouse_ids)))
    )
  )
$$;

create policy staging_limit_profile on public.profiles as restrictive for select to authenticated using ((select public.stage_member_active()));

create policy staging_limit_tasks_read on public.stage_tasks as restrictive for select to authenticated
using (public.stage_within_limits('tasks.read',show_id,null));
create policy staging_limit_tasks_update on public.stage_tasks as restrictive for update to authenticated
using (public.stage_within_limits('tasks.write',show_id,null)) with check (public.stage_within_limits('tasks.write',show_id,null));
create policy staging_limit_tasks_insert on public.stage_tasks as restrictive for insert to authenticated
with check (public.stage_within_limits('tasks.write',show_id,null));
create policy staging_limit_shows on public.shows as restrictive for select to authenticated
using (public.stage_within_limits('scope',id,null));
create policy staging_limit_warehouses on public.warehouses as restrictive for select to authenticated
using (public.stage_within_limits('scope',null,id));
create policy staging_limit_assets on public.assets as restrictive for select to authenticated
using (public.stage_within_limits('assets.read',assigned_show_id,warehouse_id));
create policy staging_limit_asset_files on storage.objects as restrictive for select to authenticated
using (bucket_id<>'asset-photos' or exists(select 1 from public.assets a where a.id::text=split_part(name,'/',1)));

revoke execute on function public.stage_team_limits(uuid,jsonb),public.stage_within_limits(text,uuid,uuid) from public,anon,authenticated;
grant execute on function public.stage_team_limits(uuid,jsonb),public.stage_within_limits(text,uuid,uuid) to authenticated;

commit;
