-- Integration candidate. Uses the existing role/individual permission and scope tables.
begin;
alter table public.profiles add column contact_phone text, add column job_title text;
alter table public.user_invitations add column onboarding jsonb;

create function stage_operations.invitation_access(p_inviter uuid,p_code text)
returns boolean language sql stable security definer set search_path=''
as $$
  select exists (
    select 1 from public.profiles p join public.roles r on r.id=p.role_id
    join public.permissions pm on pm.code=p_code
    where p.id=p_inviter and p.is_active and p.is_admin
      and r.code in ('executive_producer','creative_producer')
      and coalesce((
        select u.is_allowed from public.user_permissions u
        where u.user_id=p.id and u.permission_id=pm.id and (u.expires_at is null or u.expires_at>now())
      ), exists(select 1 from public.role_permissions rp where rp.role_id=r.id and rp.permission_id=pm.id))
  )
$$;

create function public.stage_v1_prepare_invitation(
  p_email text,p_name text,p_phone text,p_job text,p_actions text[],p_shows uuid[],p_warehouses uuid[]
) returns uuid language plpgsql security definer set search_path=''
as $$
declare
  actor uuid:=auth.uid();
  invitation uuid;
  normalized_email text:=lower(btrim(p_email));
  selected_role uuid;
  permissions text[]:=coalesce(p_actions,'{}');
begin
  if not stage_operations.invitation_access(actor,'team.invite')
    or not stage_operations.invitation_access(actor,'team.permissions') then raise insufficient_privilege; end if;
  if coalesce(length(normalized_email),0) not between 3 and 254
    or normalized_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
    or coalesce(length(btrim(p_name)),0) not between 1 and 120
    or length(coalesce(p_job,''))>120
    or (nullif(btrim(p_phone),'') is not null and
      (length(p_phone)>40 or p_phone !~ '^[+0-9][0-9 ().-]*$' or length(regexp_replace(p_phone,'[^0-9]','','g')) not between 7 and 15))
    or cardinality(permissions)>16 then raise invalid_parameter_value; end if;
  if exists(select 1 from unnest(permissions) code where code is null or
    code not in ('assets.view','assets.photos','assets.documents','assets.qr_print','reservations.create','reservations.view','shows.view','warehouses.view')
    or not stage_operations.invitation_access(actor,code)) then raise insufficient_privilege; end if;
  if exists(select 1 from unnest(p_shows) id where id is null or not exists(select 1 from public.shows s where s.id=id) or not public.has_show_access(id))
    or exists(select 1 from unnest(p_warehouses) id where id is null or not exists(select 1 from public.warehouses w where w.id=id) or not public.has_warehouse_access(id)) then raise insufficient_privilege; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(normalized_email,90210));
  if exists(select 1 from auth.users u join public.profiles p on p.id=u.id where lower(u.email)=normalized_email)
    or exists(select 1 from public.user_invitations i where lower(i.email)=normalized_email and status='pending' and expires_at>now()) then
    raise exception 'Для цієї адреси вже є профіль або активне запрошення' using errcode='23505';
  end if;
  select id into strict selected_role from public.roles where code='employee';
  insert into public.user_invitations(email,role_id,invited_by,status,expires_at,onboarding)
    values(normalized_email,selected_role,actor,'pending',now()+interval '7 days',
      jsonb_build_object('name',btrim(p_name),'job',nullif(btrim(p_job),''),'phone',nullif(btrim(p_phone),''),
        'actions',permissions,
        'shows',coalesce(p_shows,array(select id from public.shows where public.has_show_access(id))),
        'warehouses',coalesce(p_warehouses,array(select id from public.warehouses where public.has_warehouse_access(id)))))
    returning id into invitation;
  return invitation;
end;
$$;

create function public.stage_v1_claim_invitation()
returns boolean language plpgsql security definer set search_path=''
as $$
declare
  actor uuid:=auth.uid();
  email_address text;
  invite public.user_invitations%rowtype;
begin
  select lower(email) into email_address from auth.users where id=actor and email_confirmed_at is not null;
  if email_address is null or exists(select 1 from public.profiles where id=actor) then return false; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(email_address,90210));
  select * into invite from public.user_invitations where lower(email)=email_address
    and status='pending' and expires_at>now() and onboarding is not null order by created_at desc limit 1 for update;
  if not found or not stage_operations.invitation_access(invite.invited_by,'team.invite')
    or not stage_operations.invitation_access(invite.invited_by,'team.permissions')
    or not exists(select 1 from public.roles where id=invite.role_id and code='employee') then return false; end if;
  insert into public.profiles(id,full_name,role_id,is_admin,is_active,job_title,contact_phone)
    values(actor,invite.onboarding->>'name',invite.role_id,false,true,invite.onboarding->>'job',invite.onboarding->>'phone')
    on conflict(id) do nothing;
  if not found then return false; end if;
  insert into public.user_permissions(user_id,permission_id,is_allowed,granted_by)
    select actor,p.id,(invite.onboarding->'actions') ? p.code
      and p.code in ('assets.view','assets.photos','assets.documents','assets.qr_print','reservations.create','reservations.view','shows.view','warehouses.view')
      and stage_operations.invitation_access(invite.invited_by,p.code),invite.invited_by
    from public.permissions p;
  insert into public.user_show_access(user_id,show_id,granted_by)
    select actor,s.id,invite.invited_by from public.shows s where (invite.onboarding->'shows') ? s.id::text;
  insert into public.user_warehouse_access(user_id,warehouse_id,granted_by)
    select actor,w.id,invite.invited_by from public.warehouses w where (invite.onboarding->'warehouses') ? w.id::text;
  update public.user_invitations set status='accepted',accepted_at=now() where id=invite.id;
  return true;
end;
$$;
revoke execute on function stage_operations.invitation_access(uuid,text),
  public.stage_v1_prepare_invitation(text,text,text,text,text[],uuid[],uuid[]),
  public.stage_v1_claim_invitation() from public,anon,authenticated;
grant execute on function public.stage_v1_prepare_invitation(text,text,text,text,text[],uuid[],uuid[]),
  public.stage_v1_claim_invitation() to authenticated;
create function public.stage_v1_invitation_options()
returns jsonb language plpgsql stable security definer set search_path=''
as $$
begin
  if not stage_operations.invitation_access(auth.uid(),'team.invite')
    or not stage_operations.invitation_access(auth.uid(),'team.permissions') then raise insufficient_privilege; end if;
  return jsonb_build_object(
    'permissions', (select coalesce(jsonb_agg(jsonb_build_object('code',code,'name',name) order by name),'[]')
      from public.permissions where code in ('assets.view','assets.photos','assets.documents','assets.qr_print','reservations.create','reservations.view','shows.view','warehouses.view')
        and stage_operations.invitation_access(auth.uid(),code)),
    'shows',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name) order by name),'[]')
      from public.shows where public.has_show_access(id)),
    'warehouses',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name) order by name),'[]')
      from public.warehouses where public.has_warehouse_access(id)),
    'invitations',(select coalesce(jsonb_agg(to_jsonb(i) order by i.expires_at desc),'[]')
      from (select id,email,status,expires_at from public.user_invitations where invited_by=auth.uid() and onboarding is not null order by created_at desc limit 50) i)
  );
end;
$$;

create function public.stage_v1_cancel_invitation(p_id uuid)
returns void language plpgsql security definer set search_path=''
as $$
declare email_address text;
begin
  if not stage_operations.invitation_access(auth.uid(),'team.invite') then raise insufficient_privilege; end if;
  select lower(email) into email_address from public.user_invitations
    where id=p_id and invited_by=auth.uid() and onboarding is not null;
  if not found then raise insufficient_privilege; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(email_address,90210));
  update public.user_invitations set status='cancelled'
    where id=p_id and invited_by=auth.uid() and status='pending';
end;
$$;
revoke execute on function public.stage_v1_invitation_options(),public.stage_v1_cancel_invitation(uuid) from public,anon,authenticated;
grant execute on function public.stage_v1_invitation_options(),public.stage_v1_cancel_invitation(uuid) to authenticated;
commit;
