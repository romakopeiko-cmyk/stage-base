begin;

alter table public.profiles add column if not exists job_title text;
create table if not exists public.user_invitations (
  id uuid primary key default gen_random_uuid(),
  email text not null,
  role_id uuid not null references public.roles,
  invited_by uuid not null references public.profiles,
  status text not null default 'pending',
  expires_at timestamptz not null,
  accepted_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.user_invitations enable row level security;

create table public.stage_team_audit (
  id bigint generated always as identity primary key,
  actor uuid not null references public.profiles,
  subject uuid not null,
  action text not null,
  changes jsonb not null,
  created_at timestamptz not null default now()
);
alter table public.stage_team_audit enable row level security;
revoke all on public.stage_team_audit from public, anon, authenticated;

create function public.stage_team_capabilities()
returns jsonb language sql stable security definer set search_path = ''
as $$
  select coalesce((select jsonb_build_object('manage', p.is_admin, 'delegate', p.is_admin and r.code = 'executive_producer')
    from public.profiles p join public.roles r on r.id=p.role_id where p.id=auth.uid() and p.is_active),
    '{"manage":false,"delegate":false}'::jsonb)
$$;

create function public.stage_team_directory()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (public.stage_team_capabilities()->>'manage')::boolean then
    raise exception 'Керування командою недоступне' using errcode='42501';
  end if;
  return jsonb_build_object(
    'members', (select coalesce(jsonb_agg(to_jsonb(member)), '[]') from
      (select id,full_name,job_title,role_id,is_active,is_admin from public.profiles order by full_name,id) member),
    'roles', (select coalesce(jsonb_agg(to_jsonb(role)), '[]') from
      (select id,code,name from public.roles order by name) role),
    'audit', (select coalesce(jsonb_agg(to_jsonb(event)), '[]') from
      (select actor,subject,action,changes,created_at from public.stage_team_audit order by id desc limit 50) event)
  );
end;
$$;

create function public.stage_team_edit(p_user uuid,p_name text,p_job text,p_role uuid,p_active boolean,p_admin boolean)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  rights jsonb;
  member public.profiles%rowtype;
  previous_role text;
  next_role text;
begin
  perform pg_catalog.pg_advisory_xact_lock(708217955);
  rights := public.stage_team_capabilities();
  if not (rights->>'manage')::boolean then
    raise exception 'Керування командою недоступне' using errcode='42501';
  end if;
  select * into strict member from public.profiles where id=p_user for update;
  select code into strict previous_role from public.roles where id=member.role_id;
  select code into strict next_role from public.roles where id=p_role;
  if p_active is null or p_admin is null or coalesce(length(btrim(p_name)),0) not between 1 and 120
    or length(coalesce(p_job,''))>120 then
    raise exception 'Перевірте дані профілю' using errcode='22023';
  end if;
  if p_user=auth.uid() and row(p_role,p_active,p_admin) is distinct from row(member.role_id,member.is_active,member.is_admin) then
    raise exception 'Власні права може змінити інший уповноважений адміністратор' using errcode='42501';
  end if;
  if previous_role='executive_producer' or next_role='executive_producer' then
    if p_role is distinct from member.role_id or p_active is distinct from member.is_active or p_admin is distinct from member.is_admin then
      raise exception 'Роль виконавчого продюсера змінюється окремо' using errcode='42501';
    end if;
  end if;
  if not (rights->>'delegate')::boolean
    and (member.is_admin or p_admin or previous_role='creative_producer' or next_role='creative_producer'
      or p_role is distinct from member.role_id
      or (p_active and not member.is_active)) then
    raise exception 'Зміна ролі, відновлення або делегування потребує окремого повноваження' using errcode='42501';
  end if;
  if member.is_active and member.is_admin and (not p_active or not p_admin)
    and not exists(select 1 from public.profiles where id<>p_user and is_active and is_admin) then
    raise exception 'Останнього адміністратора не можна деактивувати' using errcode='23514';
  end if;
  update public.profiles set full_name=btrim(p_name),job_title=nullif(btrim(p_job),''),
    role_id=p_role,is_active=p_active,is_admin=p_admin where id=p_user;
  insert into public.stage_team_audit(actor,subject,action,changes)
    values(auth.uid(),p_user,'profile.updated',jsonb_build_object(
      'before',jsonb_build_object('name',member.full_name,'job',member.job_title,'role',member.role_id,'active',member.is_active,'admin',member.is_admin),
      'after',jsonb_build_object('name',btrim(p_name),'job',nullif(btrim(p_job),''),'role',p_role,'active',p_active,'admin',p_admin)));
end;
$$;

revoke execute on function public.stage_team_capabilities(),public.stage_team_directory(),
  public.stage_team_edit(uuid,text,text,uuid,boolean,boolean) from public,anon,authenticated;
grant execute on function public.stage_team_capabilities(),public.stage_team_directory(),
  public.stage_team_edit(uuid,text,text,uuid,boolean,boolean) to authenticated;

commit;
