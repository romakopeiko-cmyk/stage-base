-- Use a disposable local database after replaying Staging and PR #31.
begin;
insert into auth.users(id,email) values
 ('00000000-0000-4000-8000-000000000101','reader@example.invalid'),
 ('00000000-0000-4000-8000-000000000102','director@example.invalid'),
 ('00000000-0000-4000-8000-000000000103','unregistered@example.invalid');
insert into public.profiles(id,display_name,role_id,is_active)
select '00000000-0000-4000-8000-000000000101','Fixture reader',id,true from public.roles where code='employee';
insert into public.profiles(id,display_name,role_id,is_active)
select '00000000-0000-4000-8000-000000000102','Fixture director',id,true from public.roles where code='director';
insert into public.shows(id,name) values
 ('00000000-0000-4000-8000-000000000111','Fixture show'),
 ('00000000-0000-4000-8000-000000000112','Other fixture show');
insert into public.user_show_access(user_id,show_id) values
 ('00000000-0000-4000-8000-000000000101','00000000-0000-4000-8000-000000000111');
insert into public.stage_member_limits(user_id,show_ids,tasks_read,tasks_create,tasks_write,assets_read)
values ('00000000-0000-4000-8000-000000000101',
 array['00000000-0000-4000-8000-000000000111'::uuid],true,false,false,true);
insert into public.assets(id,inventory_number,name,assigned_show_id) values
 ('00000000-0000-4000-8000-000000000121','FIXTURE-1','Fixture asset','00000000-0000-4000-8000-000000000111'),
 ('00000000-0000-4000-8000-000000000122','FIXTURE-2','Other fixture asset','00000000-0000-4000-8000-000000000112');
insert into public.asset_finance(asset_id,replacement_value)
values ('00000000-0000-4000-8000-000000000121', 100);
insert into public.stage_tasks(owner_id,assigned_by,show_id,title,status)
values ('00000000-0000-4000-8000-000000000101','00000000-0000-4000-8000-000000000102',
 '00000000-0000-4000-8000-000000000111','Fixture task','doing');

set local role authenticated;
set local request.jwt.claim.sub='00000000-0000-4000-8000-000000000103';
do $$ begin
 if public.stage_member_active() or exists(select from public.stage_tasks) or exists(select from public.assets) then
   raise exception 'Unregistered access';
 end if;
end $$;
set local request.jwt.claim.sub='00000000-0000-4000-8000-000000000101';
do $$ begin
 if (select count(*) from public.stage_tasks) <> 1 or
    (select count(id) from public.assets where inventory_number like 'FIXTURE-%') <> 1 or
    exists(select from public.asset_finance) then raise exception 'Reader access mismatch'; end if;
 begin
   insert into public.stage_task_comments(task_id,author_id,body)
   select id,auth.uid(),'Fixture comment' from public.stage_tasks;
   raise exception 'Reader must not create a comment';
 exception when insufficient_privilege then null;
 end;
end $$;
reset role;
update public.stage_member_limits set tasks_write=true where user_id='00000000-0000-4000-8000-000000000101';
set local role authenticated;
insert into public.stage_task_comments(task_id,author_id,body)
select id,auth.uid(),'Allowed comment' from public.stage_tasks;
do $$ begin
 if (select count(*) from public.stage_task_comments) <> 1 then raise exception 'Writer comment missing'; end if;
end $$;
set local request.jwt.claim.sub='00000000-0000-4000-8000-000000000102';
do $$ begin
 if (select count(*) from public.asset_finance) <> 1 then raise exception 'Director finance access'; end if;
end $$;
set local request.jwt.claim.sub='00000000-0000-4000-8000-000000000101';
reset role;
update public.profiles set is_active=false where id='00000000-0000-4000-8000-000000000101';
set local role authenticated;
do $$ begin
 if public.stage_member_active() or public.stage_has_individual_access()
 or exists(select from public.stage_tasks) or exists(select from public.assets) then
   raise exception 'Deactivated actor retained access';
 end if;
end $$;
rollback;
