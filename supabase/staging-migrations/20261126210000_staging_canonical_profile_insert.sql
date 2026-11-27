-- Preserve the legacy fields required by the existing Staging profile table.
begin;

create function public.stage_v1_fill_legacy_employee_profile()
returns trigger language plpgsql security invoker set search_path = ''
as $$
begin
  if new.display_name is null or new.role is null then
    if current_user in ('anon', 'authenticated') or new.is_admin is distinct from false
      or not exists (select 1 from public.roles where id = new.role_id and code = 'employee')
      or nullif(pg_catalog.btrim(new.full_name), '') is null then
      raise exception 'Invalid canonical employee profile' using errcode = '42501';
    end if;

    new.display_name := new.full_name;
    new.role := 'staff';
    new.active := new.is_active;
  end if;
  return new;
end;
$$;
revoke execute on function public.stage_v1_fill_legacy_employee_profile() from public, anon, authenticated;

create trigger stage_v1_fill_legacy_employee_profile
before insert on public.profiles
for each row execute function public.stage_v1_fill_legacy_employee_profile();

commit;
