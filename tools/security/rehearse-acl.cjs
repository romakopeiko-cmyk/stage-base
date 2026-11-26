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
      create table public.profiles (active boolean, role text);
      create table public.notifications (
        id uuid, recipient_id uuid, notification_type text, title text, message text,
        entity_type text, entity_id uuid, is_read boolean, read_at timestamptz, created_at timestamptz
      );
      create table public.access_grants (id uuid);
      create table public.asset_events (id uuid);
      create table public.asset_finance (id uuid);
      create table public.asset_photos (id uuid);
      create table public.roles (id uuid);
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
    await db.exec(fs.readFileSync(require('node:path').join(__dirname, 'staging-acl-check.sql'), 'utf8'));
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
