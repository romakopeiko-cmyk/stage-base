-- Stage Base Staging only.
begin;
alter table public.user_invitations add column job_title text, add column access_setup jsonb;
alter table public.stage_member_limits add column tasks_create boolean, add column shows_read boolean not null default true, add column warehouses_read boolean not null default true;
update public.stage_member_limits set tasks_create=tasks_write;
alter table public.stage_member_limits alter column tasks_create set not null, alter column tasks_create set default true;
create or replace function public.stage_team_limits(p_user uuid,p_limits jsonb default null)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare s uuid[]; w uuid[]; before_update jsonb;
begin
  perform pg_catalog.pg_advisory_xact_lock(708217955);
  if not (public.stage_team_capabilities()->>'delegate')::boolean or p_user=auth.uid()
    or not exists(select 1 from public.profiles p join public.roles r on r.id=p.role_id where p.id=p_user and r.code not in ('executive_producer','creative_producer') and not p.is_admin) then
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
    insert into public.stage_member_limits(user_id,show_ids,warehouse_ids,tasks_read,tasks_write,assets_read,tasks_create,shows_read,warehouses_read)
      values(p_user,s,w,(p_limits->>'tasks_read')::boolean,(p_limits->>'tasks_write')::boolean,(p_limits->>'assets_read')::boolean,coalesce((p_limits->>'tasks_create')::boolean,(p_limits->>'tasks_write')::boolean),coalesce((p_limits->>'shows_read')::boolean,true),coalesce((p_limits->>'warehouses_read')::boolean,true))
      on conflict(user_id) do update set show_ids=excluded.show_ids,warehouse_ids=excluded.warehouse_ids,
        tasks_read=excluded.tasks_read,tasks_write=excluded.tasks_write,assets_read=excluded.assets_read,tasks_create=excluded.tasks_create,shows_read=excluded.shows_read,warehouses_read=excluded.warehouses_read;
    insert into public.stage_team_audit(actor,subject,action,changes) values(auth.uid(),p_user,'access.updated',
      jsonb_build_object('before',before_update,'after',p_limits));
  end if;
  return jsonb_build_object(
    'limits',(select to_jsonb(l) from public.stage_member_limits l where l.user_id=p_user),
    'shows',(select coalesce(jsonb_agg(to_jsonb(show_row)), '[]') from (select id,name from public.shows order by name) show_row),
    'warehouses',(select coalesce(jsonb_agg(to_jsonb(warehouse_row)), '[]') from (select id,name from public.warehouses order by name) warehouse_row));
end;
$$;


create or replace function public.stage_claim_team_invitation()
returns boolean language plpgsql security definer set search_path=''
as $$
declare item public.user_invitations%rowtype; email_address text; role_code text;
begin
  perform pg_catalog.pg_advisory_xact_lock(708217955);
  if exists(select 1 from public.profiles where id=auth.uid()) then return false; end if;
  select lower(email) into email_address from auth.users where id=auth.uid() and email_confirmed_at is not null;
  if email_address is null then return false; end if;
  select * into item from public.user_invitations where lower(email)=email_address
    and status='pending' and expires_at>now() for update;
  if not found then return false; end if;
  select code into role_code from public.roles where id=item.role_id;
  if role_code is null or role_code in ('executive_producer','creative_producer') then return false; end if;
  select id into strict item.role_id from public.roles where code='employee';
  role_code:='employee';
  insert into public.profiles(id,display_name,role,active,full_name,role_id,is_active,is_admin)
    values(auth.uid(),item.full_name,case role_code when 'line_producer' then 'show_producer'
      when 'employee' then 'staff' else role_code end,true,item.full_name,item.role_id,true,false);
  update public.profiles set job_title=item.job_title where id=auth.uid();
  insert into public.stage_member_limits(user_id,show_ids,warehouse_ids,tasks_read,tasks_write,assets_read,tasks_create,shows_read,warehouses_read)
  select auth.uid(),array(select v::uuid from jsonb_array_elements_text(coalesce(nullif(item.access_setup->'show_ids','null'::jsonb),'[]'::jsonb)) v),
    array(select v::uuid from jsonb_array_elements_text(coalesce(nullif(item.access_setup->'warehouse_ids','null'::jsonb),'[]'::jsonb)) v),
    coalesce((item.access_setup->>'tasks_read')::boolean,false),coalesce((item.access_setup->>'tasks_write')::boolean,false),coalesce((item.access_setup->>'assets_read')::boolean,false),
    coalesce((item.access_setup->>'tasks_create')::boolean,false),coalesce((item.access_setup->>'shows_read')::boolean,false),coalesce((item.access_setup->>'warehouses_read')::boolean,false);
  update public.stage_member_limits set
    show_ids=case when item.access_setup->'show_ids'='null'::jsonb then null else show_ids end,
    warehouse_ids=case when item.access_setup->'warehouse_ids'='null'::jsonb then null else warehouse_ids end where user_id=auth.uid();
  update public.user_invitations set status='accepted',accepted_at=now() where id=item.id;
  return true;
end;
$$;

create or replace function public.stage_within_limits(p_feature text,p_show uuid,p_warehouse uuid)
returns boolean language sql stable security definer set search_path=''
as $$
  select public.stage_member_active() and not exists (
    select 1 from public.stage_member_limits l where l.user_id=auth.uid() and (
      (p_feature='tasks.read' and not l.tasks_read)
      or (p_feature='tasks.create' and (not l.tasks_read or not l.tasks_create))
      or (p_feature='shows.read' and not l.shows_read)
      or (p_feature='warehouses.read' and not l.warehouses_read)
      or (p_feature='tasks.write' and (not l.tasks_read or not l.tasks_write))
      or (p_feature='assets.read' and not l.assets_read)
      or (p_show is not null and l.show_ids is not null and not (p_show=any(l.show_ids)))
      or (p_warehouse is not null and l.warehouse_ids is not null and not (p_warehouse=any(l.warehouse_ids)))
    )
  )
$$;

create or replace function public.stage_guard_limited_task_write()
returns trigger language plpgsql security definer set search_path=''
as $$
begin
  if auth.uid() is not null and not public.stage_within_limits(case when tg_op='INSERT' then 'tasks.create' else 'tasks.write' end,new.show_id,null) then
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

create function public.stage_invite_configuration()
returns jsonb language plpgsql stable security definer set search_path=''
as $$
begin
  if not (public.stage_team_capabilities()->>'delegate')::boolean then raise insufficient_privilege; end if;
  return jsonb_build_object(
    'shows',(select coalesce(jsonb_agg(to_jsonb(item)),'[]') from (select id,name from public.shows order by name) item),
    'warehouses',(select coalesce(jsonb_agg(to_jsonb(item)),'[]') from (select id,name from public.warehouses order by name) item));
end;
$$;

create function public.stage_prepare_individual_invitation(p_email text,p_name text,p_job text,p_access jsonb)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare saved jsonb; role_uuid uuid; flag text;
begin
  perform public.stage_invite_configuration();
  if length(coalesce(p_job,''))>120 or jsonb_typeof(p_access) is distinct from 'object' then raise invalid_parameter_value; end if;
  foreach flag in array array['tasks_read','tasks_write','tasks_create','shows_read','warehouses_read','assets_read']
  loop
    if jsonb_typeof(p_access->flag) is distinct from 'boolean' then raise invalid_parameter_value; end if;
  end loop;
  if coalesce(jsonb_typeof(p_access->'show_ids'),'missing') not in ('null','array') or
    coalesce(jsonb_typeof(p_access->'warehouse_ids'),'missing') not in ('null','array') then raise invalid_parameter_value; end if;
  if exists(select 1 from jsonb_array_elements_text(coalesce(nullif(p_access->'show_ids','null'::jsonb),'[]'::jsonb)) v
       where v is null or not exists(select 1 from public.shows where id=v::uuid))
    or exists(select 1 from jsonb_array_elements_text(coalesce(nullif(p_access->'warehouse_ids','null'::jsonb),'[]'::jsonb)) v
       where v is null or not exists(select 1 from public.warehouses where id=v::uuid)) then raise invalid_parameter_value; end if;
  if exists(select 1 from jsonb_object_keys(p_access) k where k not in
    ('tasks_read','tasks_write','tasks_create','shows_read','warehouses_read','assets_read','show_ids','warehouse_ids')) then raise invalid_parameter_value; end if;
  select id into strict role_uuid from public.roles where code='employee';
  saved:=public.stage_team_invitation_action('invite',null,p_email,p_name,role_uuid);
  update public.user_invitations set job_title=nullif(btrim(p_job),''),access_setup=p_access where id=(saved->>'id')::uuid;
  insert into public.stage_team_audit(actor,subject,action,changes)
    values(auth.uid(),(saved->>'id')::uuid,'invitation.access',p_access);
  return saved;
end;
$$;

revoke execute on function public.stage_prepare_individual_invitation(text,text,text,jsonb),public.stage_invite_configuration() from public,anon,authenticated;
grant execute on function public.stage_prepare_individual_invitation(text,text,text,jsonb),public.stage_invite_configuration() to authenticated;

create function public.stage_has_individual_access()
returns boolean language sql stable security definer set search_path=''
as $$ select exists(select 1 from public.stage_member_limits where user_id=auth.uid() and assets_read) $$;
revoke execute on function public.stage_has_individual_access() from public,anon;
grant execute on function public.stage_has_individual_access() to authenticated;

alter policy staging_limit_tasks_insert on public.stage_tasks with check (public.stage_within_limits('tasks.create',show_id,null));
alter policy staging_limit_shows on public.shows using (public.stage_within_limits('shows.read',id,null));
alter policy staging_limit_warehouses on public.warehouses using (public.stage_within_limits('warehouses.read',null,id));
-- Existing role paths stay intact for legacy users. Individually managed employees
-- may read allowed asset rows, with the original restrictive scope policy still applied.
create policy staging_individual_asset_read on public.assets for select to authenticated
using (public.stage_within_limits('assets.read',assigned_show_id,warehouse_id) and public.stage_has_individual_access());

commit;
