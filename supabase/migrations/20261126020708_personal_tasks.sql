begin;

create table public.stage_tasks (
  id bigint generated always as identity primary key,
  owner_id uuid not null default auth.uid() references public.profiles(id),
  title text not null check (length(btrim(title)) between 1 and 180),
  description text check (length(description) <= 8000),
  priority text not null default 'medium' check (priority in ('critical','high','medium','low')),
  status text not null default 'planned' check (status in ('planned','todo','doing','review','done','blocked')),
  starts_at timestamptz,
  due_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (starts_at is null or isfinite(starts_at)),
  check (due_at is null or isfinite(due_at)),
  check (due_at is null or starts_at is null or starts_at <= due_at)
);

create index stage_tasks_owner_due_idx on public.stage_tasks(owner_id,due_at,id);

create table public.stage_task_history (
  id bigint generated always as identity primary key,
  task_id bigint not null references public.stage_tasks(id),
  actor_id uuid not null references public.profiles(id),
  changes jsonb not null,
  created_at timestamptz not null default now()
);

create index stage_task_history_task_idx on public.stage_task_history(task_id,id);
alter table public.stage_tasks enable row level security;
alter table public.stage_task_history enable row level security;
revoke all on public.stage_tasks, public.stage_task_history from public,anon,authenticated;
grant select on public.stage_tasks, public.stage_task_history to authenticated;
grant insert (title,description,priority,starts_at,due_at) on public.stage_tasks to authenticated;
grant update (title,description,priority,status,starts_at,due_at) on public.stage_tasks to authenticated;

create policy stage_tasks_owner_read on public.stage_tasks for select to authenticated
  using (owner_id = (select auth.uid()) and exists (
    select 1 from public.profiles where id = (select auth.uid()) and is_active
  ));
create policy stage_tasks_owner_create on public.stage_tasks for insert to authenticated
  with check (owner_id = (select auth.uid()) and exists (
    select 1 from public.profiles where id = (select auth.uid()) and is_active
  ));
create policy stage_tasks_owner_update on public.stage_tasks for update to authenticated
  using (owner_id = (select auth.uid()) and exists (
    select 1 from public.profiles where id = (select auth.uid()) and is_active
  ))
  with check (owner_id = (select auth.uid()) and exists (
    select 1 from public.profiles where id = (select auth.uid()) and is_active
  ));
create policy stage_task_history_owner_read on public.stage_task_history for select to authenticated
  using (exists (select 1 from public.stage_tasks where id = task_id));

create function stage_operations.task_timestamps()
returns trigger language plpgsql security invoker set search_path = ''
as $$
begin
  new.updated_at := statement_timestamp();
  if new.status = 'done' and old.status <> 'done' then
    new.completed_at := statement_timestamp();
  elsif new.status <> 'done' then
    new.completed_at := null;
  end if;
  return new;
end;
$$;

create function stage_operations.task_record_history()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if auth.uid() is not null then
    insert into public.stage_task_history(task_id,actor_id,changes) values (
      new.id,auth.uid(),jsonb_build_object(
        'before',case when tg_op = 'UPDATE' then to_jsonb(old) end,
        'after',to_jsonb(new)
      )
    );
  end if;
  return new;
end;
$$;

revoke execute on function stage_operations.task_timestamps(),stage_operations.task_record_history()
  from public,anon,authenticated;

create trigger stage_task_timestamps before update on public.stage_tasks
  for each row execute function stage_operations.task_timestamps();
create trigger stage_task_history after insert or update on public.stage_tasks
  for each row execute function stage_operations.task_record_history();

commit;
