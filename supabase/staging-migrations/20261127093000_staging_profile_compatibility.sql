-- Staging only. Canonical profile fields drive legacy compatibility columns.
begin;

create function public.stage_sync_profile_compatibility()
returns trigger language plpgsql security invoker set search_path=''
as $$
declare
  role_code text;
begin
  if current_user in ('anon','authenticated') then
    if tg_op = 'INSERT' then
      raise insufficient_privilege;
    end if;
    if row(new.active,new.role,new.is_active,new.role_id,new.is_admin)
       is distinct from row(old.active,old.role,old.is_active,old.role_id,old.is_admin) then
      raise insufficient_privilege;
    end if;
    return new;
  end if;

  select r.code into strict role_code from public.roles r where r.id=new.role_id;
  new.role := case role_code
    when 'executive_producer' then 'head_producer'
    when 'line_producer' then 'show_producer'
    when 'employee' then 'staff'
    else role_code
  end;
  new.active := new.is_active;
  return new;
end;
$$;
revoke execute on function public.stage_sync_profile_compatibility() from public, anon, authenticated;
create trigger stage_sync_profile_compatibility
before insert or update on public.profiles
for each row execute function public.stage_sync_profile_compatibility();

-- Route any drift through the same trigger. Do not rewrite already aligned rows.
update public.profiles p set active=p.is_active
from public.roles r
where p.role_id=r.id and
  (p.active is distinct from p.is_active or p.role is distinct from
    case r.code when 'executive_producer' then 'head_producer'
      when 'line_producer' then 'show_producer' when 'employee' then 'staff' else r.code end);

-- A disabled profile must not retain an affirmative grant helper result.
create or replace function public.stage_has_individual_access()
returns boolean language sql stable security definer set search_path=''
as $$
  select public.stage_member_active() and exists (
    select 1 from public.stage_member_limits
    where user_id=(select auth.uid()) and assets_read
  )
$$;

-- Comment writers must participate in the task. Read-only visibility is insufficient.
alter policy stage_task_comments_write on public.stage_task_comments
with check (
  author_id=(select auth.uid()) and exists (
    select 1 from public.stage_tasks t
    where t.id=stage_task_comments.task_id
      and (t.owner_id=(select auth.uid()) or t.assigned_by=(select auth.uid()))
  )
);

do $$
declare item record;
begin
  for item in select n.nspname,c.relname from pg_class c
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname in ('public','stage_operations') and c.relkind in ('r','p')
  loop
    execute format('revoke truncate, trigger on table %I.%I from public, anon, authenticated',
      item.nspname,item.relname);
    if has_table_privilege('anon',format('%I.%I',item.nspname,item.relname),'TRUNCATE,TRIGGER')
      or has_table_privilege('authenticated',format('%I.%I',item.nspname,item.relname),'TRUNCATE,TRIGGER') then
      raise exception 'Inherited excess client privileges on %.%',item.nspname,item.relname;
    end if;
  end loop;
end;
$$;

commit;
