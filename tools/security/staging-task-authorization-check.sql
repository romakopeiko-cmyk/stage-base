-- Run as database owner after the candidate migrations. Catalog assertions only.
do $$
declare test record;
begin
  for test in
    select * from (values
      ('public','stage_tasks','staging_limit_tasks_read','tasks.read','qual'),
      ('public','stage_tasks','staging_limit_tasks_insert','tasks.create','with_check'),
      ('public','stage_tasks','staging_limit_tasks_update','tasks.write','both'),
      ('public','stage_task_comments','stage_task_comments_write','tasks.write','with_check'),
      ('public','stage_task_steps','stage_task_steps_add','tasks.write','with_check'),
      ('public','stage_task_steps','stage_task_steps_update','tasks.write','both'),
      ('storage','objects','stage_task_files_upload','tasks.write','with_check')
    ) as v(schema_name,relation_name,policy_name,feature,predicate)
  loop
    if not exists (
      select 1 from pg_policies p
      where p.schemaname=test.schema_name and p.tablename=test.relation_name and p.policyname=test.policy_name
        and (test.predicate='with_check' or position(test.feature in coalesce(p.qual,''))>0)
        and (test.predicate='qual' or position(test.feature in coalesce(p.with_check,''))>0)
    ) then
      raise exception 'Task feature check missing in policy %',test.policy_name;
    end if;
  end loop;
end;
$$;
