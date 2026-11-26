begin;

insert into storage.buckets (id, name, public, file_size_limit)
values ('stage-task-files', 'stage-task-files', false, 20971520);

create policy stage_task_files_read on storage.objects for select to authenticated
using (
  bucket_id = 'stage-task-files'
  and exists (
    select 1 from public.stage_tasks task
    where task.id::text = split_part(name, '/', 1)
  )
);

create policy stage_task_files_upload on storage.objects for insert to authenticated
with check (
  bucket_id = 'stage-task-files'
  and name ~ '^[0-9]+/[0-9a-f-]{36}/[^/]+$'
  and split_part(name, '/', 2) = (select auth.uid())::text
  and exists (
    select 1 from public.stage_tasks task
    where task.id::text = split_part(name, '/', 1)
      and task.owner_id = (select auth.uid())
      and task.status = 'doing'
      and task.assigned_by is not null
  )
);

create function stage_operations.guard_team_task_review()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if old.assigned_by is null or old.status = new.status then
    return new;
  end if;

  if old.status = 'review' or new.status = 'done' then
    if old.status <> 'review'
      or new.status not in ('done', 'doing')
      or auth.uid() is distinct from old.assigned_by
      or not coalesce(public.has_permission('team.manage'), false)
      or not coalesce(public.has_show_access(old.show_id), false) then
      raise exception 'Рішення за результатом перевірки доступне автору завдання' using errcode = '42501';
    end if;
  elsif new.status = 'review' then
    if old.status <> 'doing' or auth.uid() is distinct from old.owner_id then
      raise exception 'Передати на перевірку може виконавець завдання в роботі' using errcode = '42501';
    end if;
    insert into public.notifications (recipient_id, notification_type, title, message, entity_type)
    values (old.assigned_by, 'task_review_requested', 'Завдання на перевірці',
      'Виконавець передав вам завдання на перевірку.', 'task');
  end if;
  return new;
end;
$$;

create trigger stage_team_task_review before update of status on public.stage_tasks
for each row execute function stage_operations.guard_team_task_review();

create function public.stage_decide_team_task(p_task bigint, p_accept boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  task public.stage_tasks%rowtype;
begin
  select * into task from public.stage_tasks where id = p_task for update;
  if not found or task.assigned_by is null or auth.uid() is distinct from task.assigned_by
    or not coalesce(public.has_permission('team.manage'), false)
    or not coalesce(public.has_show_access(task.show_id), false) then
    raise exception 'Завдання недоступне для погодження' using errcode = '42501';
  end if;

  if task.status <> 'review' or p_accept is null then
    raise exception 'Завдання має очікувати перевірку' using errcode = '22023';
  end if;
  if not p_accept and coalesce(length(btrim(p_reason)), 0) not between 1 and 4000 then
    raise exception 'Укажіть причину повернення на доопрацювання' using errcode = '22023';
  end if;

  update public.stage_tasks set status = case when p_accept then 'done' else 'doing' end where id = task.id;
  if not p_accept then
    insert into public.stage_task_comments (task_id, author_id, body)
    values (task.id, auth.uid(), btrim(p_reason));
  end if;

  insert into public.notifications (recipient_id, notification_type, title, message, entity_type)
  values (task.owner_id, case when p_accept then 'task_review_accepted' else 'task_review_returned' end,
    case when p_accept then 'Результат прийнято' else 'На доопрацювання' end,
    'Відкрийте завдання, щоб переглянути рішення автора.', 'task');
end;
$$;

revoke execute on function stage_operations.guard_team_task_review() from public, anon, authenticated;
revoke execute on function public.stage_decide_team_task(bigint, boolean, text) from public, anon, authenticated;
grant execute on function public.stage_decide_team_task(bigint, boolean, text) to authenticated;

commit;
