'use strict';
const fs = require('node:fs');
const { PGlite } = require('@electric-sql/pglite');
const migration = '../../supabase/staging-migrations/20261127090000_staging_security_hardening.sql';

async function rehearse() {
  const db = new PGlite();
  try {
    await db.exec(`
      create role anon;
      create role authenticated;
      create schema storage;
      create table storage.objects (bucket_id text, name text);
      alter table storage.objects enable row level security;
      create table public.assets (id uuid, archived boolean);
      create schema auth;
      create function auth.uid() returns uuid language sql
        as 'select nullif(current_setting(''test.actor'',true),'''')::uuid';
      grant usage on schema auth to authenticated;
      create function public.stage_member_active() returns boolean language sql as 'select false';
      create table public.stage_member_limits (user_id uuid, assets_read bool);
      create table public.profiles (active boolean, role text, is_active boolean, role_id uuid, is_admin boolean);
      create table public.stage_tasks (id bigint, owner_id uuid, assigned_by uuid);
      create table public.stage_task_comments (task_id bigint, author_id uuid);
      create policy stage_task_comments_write on public.stage_task_comments for insert with check (true);
      create table public.notifications (
        id uuid, recipient_id uuid, notification_type text, title text, message text,
        entity_type text, entity_id uuid, is_read boolean, read_at timestamptz, created_at timestamptz
      );
      create table public.access_grants (id uuid);
      create table public.asset_events (id uuid);
      create table public.asset_finance (id uuid);
      create table public.asset_photos (id uuid);
      create table public.roles (id uuid, code text);
      create table public.shows (id uuid);
      create table public.user_show_access (id uuid);
      create table public.warehouses (id uuid);
      create function public.can_read_asset(uuid,uuid) returns boolean language sql as 'select false';
      grant execute on function public.can_read_asset(uuid,uuid) to authenticated;
      create policy staging_limit_asset_files on storage.objects as restrictive for select to authenticated using (false);
      alter default privileges for role postgres in schema public grant truncate, trigger on tables to anon, authenticated;
      grant truncate, trigger on all tables in schema public to public, anon, authenticated;
      grant update on public.notifications to anon, authenticated;
    `);
    await db.exec(fs.readFileSync(require('node:path').resolve(__dirname, migration), 'utf8'));
    await db.exec(fs.readFileSync(require('node:path').resolve(__dirname,
      '../../supabase/staging-migrations/20261127093000_staging_profile_compatibility.sql'), 'utf8'));
    await db.exec(fs.readFileSync(require('node:path').join(__dirname, 'staging-acl-check.sql'), 'utf8'));
    await db.exec(`
      insert into public.roles values
         ('00000000-0000-0000-0000-000000000001','executive_producer'),
         ('00000000-0000-0000-0000-000000000002','line_producer'),
         ('00000000-0000-0000-0000-000000000003','employee');
      insert into public.profiles (is_active,role_id,is_admin)
        select true,id,false from public.roles;
      update public.profiles set is_active=false;
      grant update,select on public.profiles to authenticated;
      grant select on public.stage_tasks to authenticated;
      grant insert on public.stage_task_comments to authenticated;
      alter table public.stage_task_comments enable row level security;
      insert into public.stage_tasks values
        (1,'00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002');

    `);
    const { rows } = await db.query('select role,active from public.profiles order by role');
    const assert = require('node:assert/strict');
    assert.deepEqual(rows, [
      { role: 'head_producer', active: false },
      { role: 'show_producer', active: false },
      { role: 'staff', active: false }
    ]);
    await db.exec('set role authenticated');
    await assert.rejects(db.exec('update public.profiles set active=true'), { code: '42501' });
    await db.exec("set test.actor='00000000-0000-0000-0000-000000000003'");
    await assert.rejects(db.exec('insert into public.stage_task_comments values (1,auth.uid())'), { code: '42501' });
    await db.exec("set test.actor='00000000-0000-0000-0000-000000000001'");
    await db.exec('insert into public.stage_task_comments values (1,auth.uid())');
    await db.exec('reset role');

    await db.exec(`
      create table public.future_table (id integer);
      do $$
      begin
        if has_table_privilege('anon','public.future_table','TRUNCATE, TRIGGER')
           or has_table_privilege('authenticated','public.future_table','TRUNCATE, TRIGGER') then
          raise exception 'Unexpected default client grants';
        end if;
      end;
      $$;
    `);
    console.log('Stage Base Staging ACL checks passed');
  } finally {
    await db.close();
  }
}

rehearse().catch(error => { console.error(error); process.exitCode = 1; });
