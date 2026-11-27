'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { PGlite } = require('@electric-sql/pglite');

async function rehearse() {
  const db = new PGlite();
  const actor = '00000000-0000-0000-0000-000000000001';
  const manager = '00000000-0000-0000-0000-000000000002';
  const show = '00000000-0000-0000-0000-000000000003';
  const upload = `insert into storage.objects values ('stage-task-files','1/${actor}/photo.png')`;
  try {
    await db.exec(`
      create role authenticated;
      create schema auth;
      create schema storage;
      grant usage on schema auth,storage to authenticated;
      create function auth.uid() returns uuid language sql as $$select '${actor}'::uuid$$;
      create table public.stage_test_limits (active bool, task_read bool, task_write bool, task_create bool, show_id uuid);
      insert into public.stage_test_limits values (true,true,false,false,'${show}');
      create function public.stage_within_limits(feature text, project uuid, warehouse uuid)
      returns boolean language sql stable security definer set search_path='' as $$
        select active and task_read and (project is null or project = show_id)
          and case feature when 'tasks.write' then task_write
            when 'tasks.create' then task_create else true end
        from public.stage_test_limits
      $$;
      create table public.stage_tasks (id bigint, owner_id uuid, assigned_by uuid, show_id uuid, status text);
      insert into public.stage_tasks values (1,'${actor}','${manager}','${show}','doing');
      create table public.stage_task_comments (task_id bigint, author_id uuid);
      create table public.stage_task_steps (task_id bigint, done bool);
      insert into public.stage_task_steps values(1,false);
      create table storage.objects (bucket_id text, name text);
      alter table public.stage_tasks enable row level security;
      alter table public.stage_task_comments enable row level security;
      alter table public.stage_task_steps enable row level security;
      alter table storage.objects enable row level security;
      grant select,insert,update on public.stage_tasks,public.stage_task_steps,public.stage_task_comments,storage.objects to authenticated;
      create policy staging_limit_tasks_read on public.stage_tasks for select to authenticated
        using (public.stage_within_limits('tasks.read',show_id,null));
      create policy staging_limit_tasks_insert on public.stage_tasks for insert to authenticated
        with check (public.stage_within_limits('tasks.create',show_id,null));
      create policy staging_limit_tasks_update on public.stage_tasks for update to authenticated
        using (public.stage_within_limits('tasks.write',show_id,null))
        with check (public.stage_within_limits('tasks.write',show_id,null));
      create policy stage_task_comments_write on public.stage_task_comments for insert to authenticated with check(true);
      create policy stage_task_steps_add on public.stage_task_steps for insert to authenticated with check(true);
      create policy stage_task_steps_update on public.stage_task_steps for update to authenticated using(true);
      create policy stage_task_steps_read on public.stage_task_steps for select to authenticated
        using(exists(select 1 from public.stage_tasks t where t.id=stage_task_steps.task_id));
      create policy stage_task_files_upload on storage.objects for insert to authenticated with check(true);
    `);
    await db.exec(fs.readFileSync(path.resolve(__dirname,
      '../../supabase/staging-migrations/20261127100000_staging_task_individual_write.sql'),'utf8'));
    await db.exec(fs.readFileSync(path.join(__dirname,'staging-task-authorization-check.sql'),'utf8'));
    await db.exec('set role authenticated');
    assert.equal((await db.query('select id from public.stage_tasks')).rows.length,1);
    await assert.rejects(db.exec('insert into public.stage_task_comments values(1,auth.uid())'), { code:'42501' });
    await assert.rejects(db.exec('insert into public.stage_task_steps values(1,true)'), { code:'42501' });
    assert.equal((await db.query('update public.stage_task_steps set done=true')).affectedRows,0);
    await assert.rejects(db.exec(upload), { code:'42501' });
    await db.exec('reset role; update public.stage_test_limits set task_write=true; set role authenticated');
    await db.exec('insert into public.stage_task_comments values(1,auth.uid()); insert into public.stage_task_steps values(1,true)');
    assert.equal((await db.query('update public.stage_task_steps set done=true')).affectedRows,2);
    await db.exec(upload);
    await db.exec('reset role; update public.stage_test_limits set active=false; set role authenticated');
    assert.equal((await db.query('select id from public.stage_tasks')).rows.length,0);
    await assert.rejects(db.exec('insert into public.stage_task_comments values(1,auth.uid())'), { code:'42501' });
    await assert.rejects(db.exec(upload), { code:'42501' });
    console.log('Task authorization rehearsal passed');
  } finally {
    await db.close();
  }
}

rehearse().catch(error => { console.error(error.message); process.exitCode=1; });
