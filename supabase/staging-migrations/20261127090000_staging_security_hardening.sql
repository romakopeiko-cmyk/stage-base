-- Apply only to Stage Base Staging after review.
begin;

revoke truncate, trigger on table
  public.access_grants, public.asset_events, public.asset_finance,
  public.asset_photos, public.assets, public.notifications, public.profiles,
  public.roles, public.shows, public.user_show_access, public.warehouses
from public, anon, authenticated;

alter default privileges for role postgres in schema public
  revoke truncate, trigger on tables from public, anon, authenticated;

revoke update on public.notifications from public, anon, authenticated;
revoke update (id, recipient_id, notification_type, title, message,
  entity_type, entity_id, is_read, read_at, created_at)
  on public.notifications from public, anon, authenticated;
grant update (is_read) on public.notifications to authenticated;

revoke execute on function public.can_read_asset(uuid,uuid) from public, anon;

-- Legacy asset paths start with the asset UUID. Asset RLS enforces row scope.
-- Keep the existing restrictive policy; this does not authorize a new bucket.
alter policy staging_limit_asset_files on storage.objects to authenticated
using (
  bucket_id <> 'asset-photos' or exists (
    select 1 from public.assets a
    where a.id::text = split_part(objects.name,'/',1)
      and not a.archived
  )
);

-- The existing profile guard handles canonical fields. Guard legacy fields
-- independently so the compatibility layer cannot override that check.
create function public.stage_guard_legacy_profile_fields()
returns trigger language plpgsql security invoker set search_path=''
as $$
begin
  if current_user in ('anon','authenticated')
     and row(new.active,new.role) is distinct from row(old.active,old.role) then
    raise insufficient_privilege;
  end if;
  return new;
end;
$$;
revoke execute on function public.stage_guard_legacy_profile_fields() from public, anon, authenticated;
create trigger stage_guard_legacy_profile_fields before update on public.profiles
for each row execute function public.stage_guard_legacy_profile_fields();

commit;
