-- Staging only. Keep task participation, scope and feature rights independent.
begin;

alter policy stage_task_comments_write on public.stage_task_comments
with check (
  author_id=(select auth.uid()) and exists (
    select 1 from public.stage_tasks t
    where t.id=stage_task_comments.task_id
      and (t.owner_id=(select auth.uid()) or t.assigned_by=(select auth.uid()))
      and public.stage_within_limits('tasks.write',t.show_id,null)
  )
);

alter policy stage_task_steps_add on public.stage_task_steps
with check (
  exists (
    select 1 from public.stage_tasks t
    where t.id=stage_task_steps.task_id and t.owner_id=(select auth.uid())
      and public.stage_within_limits('tasks.write',t.show_id,null)
  )
);

alter policy stage_task_steps_update on public.stage_task_steps
using (
  exists (
    select 1 from public.stage_tasks t
    where t.id=stage_task_steps.task_id and t.owner_id=(select auth.uid())
      and public.stage_within_limits('tasks.write',t.show_id,null)
  )
)
with check (
  exists (
    select 1 from public.stage_tasks t
    where t.id=stage_task_steps.task_id and t.owner_id=(select auth.uid())
      and public.stage_within_limits('tasks.write',t.show_id,null)
  )
);

alter policy stage_task_files_upload on storage.objects
with check (
  bucket_id='stage-task-files'
  and name ~ '^[0-9]+/[0-9a-f-]{36}/[^/]+$'
  and split_part(name,'/',2)=(select auth.uid())::text
  and exists (
    select 1 from public.stage_tasks t
    where t.id::text=split_part(objects.name,'/',1)
      and t.owner_id=(select auth.uid()) and t.status='doing' and t.assigned_by is not null
      and public.stage_within_limits('tasks.write',t.show_id,null)
  )
);

commit;
