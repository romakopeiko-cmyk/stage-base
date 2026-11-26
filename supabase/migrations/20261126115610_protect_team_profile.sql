begin;
create function public.stage_protect_team_profile()
returns trigger language plpgsql set search_path=''
as $$
begin
  if current_user in ('authenticated','anon') and
    row(new.role_id,new.is_active,new.is_admin) is distinct from row(old.role_id,old.is_active,old.is_admin) then
    raise exception 'Змініть права через розділ «Команда»' using errcode='42501';
  end if;
  return new;
end;
$$;
revoke execute on function public.stage_protect_team_profile() from public,anon,authenticated;
create trigger stage_protect_team_profile before update on public.profiles
for each row execute function public.stage_protect_team_profile();
commit;
