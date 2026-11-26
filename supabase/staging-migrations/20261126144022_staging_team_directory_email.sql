-- Stage Base Staging only.
begin;
create or replace function public.stage_team_directory()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (public.stage_team_capabilities()->>'manage')::boolean then
    raise exception 'Керування командою недоступне' using errcode='42501';
  end if;
  return jsonb_build_object(
    'members', (select coalesce(jsonb_agg(to_jsonb(member)), '[]') from
      (select p.id,p.full_name,p.job_title,p.role_id,p.is_active,p.is_admin,u.email from public.profiles p left join auth.users u on u.id=p.id order by p.full_name,p.id) member),
    'roles', (select coalesce(jsonb_agg(to_jsonb(role)), '[]') from
      (select id,code,name from public.roles order by name) role),
    'audit', (select coalesce(jsonb_agg(to_jsonb(event)), '[]') from
      (select actor,subject,action,changes,created_at from public.stage_team_audit order by id desc limit 50) event)
  );
end;
$$;

commit;
