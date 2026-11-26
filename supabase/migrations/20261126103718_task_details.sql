begin;
create table public.stage_task_comments (
  id bigint generated always as identity primary key,
  task_id bigint not null references public.stage_tasks(id),
  author_id uuid not null default auth.uid() references public.profiles(id),
  body text not null check (length(btrim(body)) between 1 and 4000),
  created_at timestamptz not null default now()
);
create index stage_task_comments_parent on public.stage_task_comments(task_id,id);

create table public.stage_task_steps (
  id bigint generated always as identity primary key,
  task_id bigint not null references public.stage_tasks(id),
  title text not null check (length(btrim(title)) between 1 and 180),
  is_done boolean not null default false,
  created_at timestamptz not null default now()
);
create index stage_task_steps_parent on public.stage_task_steps(task_id,id);

alter table public.stage_task_comments enable row level security;
alter table public.stage_task_steps enable row level security;
revoke all on public.stage_task_comments, public.stage_task_steps from public,anon,authenticated;
grant select on public.stage_task_comments, public.stage_task_steps to authenticated;
grant insert(task_id,body) on public.stage_task_comments to authenticated;
grant insert(task_id,title) on public.stage_task_steps to authenticated;
grant update(is_done) on public.stage_task_steps to authenticated;

create policy stage_task_comments_read on public.stage_task_comments for select to authenticated
  using (exists (select 1 from public.stage_tasks t where t.id=task_id));
create policy stage_task_comments_write on public.stage_task_comments for insert to authenticated
  with check (author_id=(select auth.uid()) and exists(select 1 from public.stage_tasks t where t.id=task_id));
create policy stage_task_steps_read on public.stage_task_steps for select to authenticated
  using (exists (select 1 from public.stage_tasks t where t.id=task_id));
create policy stage_task_steps_add on public.stage_task_steps for insert to authenticated
  with check (exists (select 1 from public.stage_tasks t where t.id=task_id and t.owner_id=(select auth.uid())));
create policy stage_task_steps_update on public.stage_task_steps for update to authenticated
  using (exists (select 1 from public.stage_tasks t where t.id=task_id and t.owner_id=(select auth.uid())))
  with check (exists (select 1 from public.stage_tasks t where t.id=task_id and t.owner_id=(select auth.uid())));
commit;
