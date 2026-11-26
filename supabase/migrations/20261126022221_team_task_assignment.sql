begin;

alter table public.stage_tasks
  add column assigned_by uuid references public.profiles(id),
  add column show_id uuid references public.shows(id),
  add constraint stage_task_assignment_scope check ((assigned_by is null) = (show_id is null));

create index stage_tasks_assigned_by_idx on public.stage_tasks(assigned_by,id) where assigned_by is not null;

alter policy stage_tasks_owner_read on public.stage_tasks using (
  exists (select 1 from public.profiles where id=(select auth.uid()) and is_active)
  and (
    (owner_id=(select auth.uid()) and (show_id is null or public.has_show_access(show_id)))
    or (assigned_by=(select auth.uid()) and public.has_permission('team.manage') and public.has_show_access(show_id))
  )
);
create policy stage_tasks_show_update on public.stage_tasks as restrictive for update to authenticated
  using (show_id is null or public.has_show_access(show_id))
  with check (show_id is null or public.has_show_access(show_id));

create function stage_operations.team_task_people(target_show uuid)
returns table(id uuid,name text) language sql stable security definer set search_path=''
as $$
 select p.id,p.full_name from public.profiles p join public.roles r on r.id=p.role_id
 where auth.uid() is not null and public.has_permission('team.manage') and public.has_show_access(target_show)
   and exists (select 1 from public.shows where shows.id=target_show and status='active')
   and p.is_active and p.id<>auth.uid() and (
     r.code in ('executive_producer','creative_producer','director','finance_director','warehouse_manager')
     or exists (select 1 from public.user_show_access a where a.user_id=p.id and a.show_id=target_show)
   )
 order by p.full_name,p.id;
$$;

create function stage_operations.team_task_assign(target_show uuid, assignee uuid, task_title text,
 task_description text, task_priority text, task_start timestamptz, task_due timestamptz)
returns bigint language plpgsql security definer set search_path=''
as $$
declare
  task_id bigint;
begin
  if not exists (select 1 from stage_operations.team_task_people(target_show) person where person.id=assignee) then
    raise exception 'Виконавець або шоу недоступні' using errcode='42501';
  end if;
  insert into public.stage_tasks(owner_id,assigned_by,show_id,title,description,priority,status,starts_at,due_at)
  values(assignee,auth.uid(),target_show,btrim(task_title),task_description,task_priority,'todo',task_start,task_due)
  returning id into task_id;
  insert into public.notifications(recipient_id,notification_type,title,message,entity_type)
  values(assignee,'task_assigned','Нове завдання','Вам призначено завдання. Відкрийте «Мої завдання».','task');
  return task_id;
end;
$$;

create function stage_operations.guard_team_task_fields()
returns trigger language plpgsql security invoker set search_path=''
as $$
begin
  if old.assigned_by is not null and current_user='authenticated'
    and row(new.title,new.description,new.priority,new.starts_at,new.due_at)
        is distinct from row(old.title,old.description,old.priority,old.starts_at,old.due_at) then
    raise exception 'Виконавець може змінювати статус командного завдання' using errcode='42501';
  end if;
  return new;
end;
$$;
create trigger stage_guard_team_task_fields before update on public.stage_tasks
for each row execute function stage_operations.guard_team_task_fields();

create function public.stage_team_task_people(p_show uuid)
returns table(id uuid,name text) language sql stable security invoker set search_path=''
as $$ select * from stage_operations.team_task_people(p_show); $$;
create function public.stage_team_task_assign(p_show uuid,p_assignee uuid,p_title text,
 p_description text,p_priority text,p_start timestamptz,p_due timestamptz)
returns bigint language sql security invoker set search_path=''
as $$ select stage_operations.team_task_assign(p_show,p_assignee,p_title,p_description,p_priority,p_start,p_due); $$;

revoke execute on function stage_operations.guard_team_task_fields(),stage_operations.team_task_people(uuid),
 stage_operations.team_task_assign(uuid,uuid,text,text,text,timestamptz,timestamptz),
 public.stage_team_task_people(uuid),public.stage_team_task_assign(uuid,uuid,text,text,text,timestamptz,timestamptz)
 from public,anon,authenticated;
grant execute on function stage_operations.team_task_people(uuid),
 stage_operations.team_task_assign(uuid,uuid,text,text,text,timestamptz,timestamptz),
 public.stage_team_task_people(uuid),public.stage_team_task_assign(uuid,uuid,text,text,text,timestamptz,timestamptz)
 to authenticated;

commit;
