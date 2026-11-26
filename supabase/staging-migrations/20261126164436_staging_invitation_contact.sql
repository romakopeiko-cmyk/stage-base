-- Stage Base Staging only.
begin;
alter table public.user_invitations add column contact_phone text;
alter table public.profiles add column contact_phone text;
-- Existing profile RLS continues to govern access to the stored number.
create function public.stage_prepare_contact_invitation(
  p_email text,p_name text,p_job text,p_phone text,p_access jsonb,p_admin boolean default false
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare saved jsonb;
begin
  if p_phone is not null and length(btrim(p_phone))>0 and
    (length(btrim(p_phone))>40 or btrim(p_phone) !~ '^[+0-9][0-9 ().-]*$' or
      length(regexp_replace(p_phone,'[^0-9]','','g')) not between 7 and 15) then
    raise exception 'Перевірте контактний номер телефону' using errcode='22023';
  end if;
  saved:=public.stage_prepare_individual_invitation(p_email,p_name,p_job,p_access,p_admin);
  update public.user_invitations set contact_phone=nullif(btrim(p_phone),'')
    where id=(saved->>'id')::uuid and invited_by=auth.uid() and status='pending';
  if not found then raise insufficient_privilege; end if;
  return saved;
end;
$$;
revoke execute on function public.stage_prepare_contact_invitation(text,text,text,text,jsonb,boolean) from public,anon,authenticated;
grant execute on function public.stage_prepare_contact_invitation(text,text,text,text,jsonb,boolean) to authenticated;

create or replace function public.stage_claim_team_invitation()
returns boolean language plpgsql security definer set search_path=''
as $$
declare item public.user_invitations%rowtype; email_address text; role_code text; grant_admin boolean;
begin
  perform pg_catalog.pg_advisory_xact_lock(708217955);
  if exists(select 1 from public.profiles where id=auth.uid()) then return false; end if;
  select lower(email) into email_address from auth.users where id=auth.uid() and email_confirmed_at is not null;
  if email_address is null then return false; end if;
  select * into item from public.user_invitations where lower(email)=email_address
    and status='pending' and expires_at>now() for update;
  if not found then return false; end if;
  select code into role_code from public.roles where id=item.role_id;
  if role_code is null or role_code in ('executive_producer','creative_producer') then return false; end if;
  select id into strict item.role_id from public.roles where code='employee';
  role_code:='employee';
  select item.requested_admin and exists (
    select 1 from public.profiles inviter join public.roles r on r.id=inviter.role_id
    where inviter.id=item.invited_by and inviter.is_active and inviter.is_admin
      and r.code in ('executive_producer','creative_producer')
  ) into grant_admin;
  insert into public.profiles(id,display_name,role,active,full_name,role_id,is_active,is_admin)
    values(auth.uid(),item.full_name,case role_code when 'line_producer' then 'show_producer'
      when 'employee' then 'staff' else role_code end,true,item.full_name,item.role_id,true,grant_admin);
  update public.profiles set job_title=item.job_title, contact_phone=item.contact_phone where id=auth.uid();
  insert into public.stage_member_limits(user_id,show_ids,warehouse_ids,tasks_read,tasks_write,assets_read,tasks_create,shows_read,warehouses_read)
  select auth.uid(),array(select v::uuid from jsonb_array_elements_text(coalesce(nullif(item.access_setup->'show_ids','null'::jsonb),'[]'::jsonb)) v),
    array(select v::uuid from jsonb_array_elements_text(coalesce(nullif(item.access_setup->'warehouse_ids','null'::jsonb),'[]'::jsonb)) v),
    coalesce((item.access_setup->>'tasks_read')::boolean,false),coalesce((item.access_setup->>'tasks_write')::boolean,false),coalesce((item.access_setup->>'assets_read')::boolean,false),
    coalesce((item.access_setup->>'tasks_create')::boolean,false),coalesce((item.access_setup->>'shows_read')::boolean,false),coalesce((item.access_setup->>'warehouses_read')::boolean,false);
  update public.stage_member_limits set
    show_ids=case when item.access_setup->'show_ids'='null'::jsonb then null else show_ids end,
    warehouse_ids=case when item.access_setup->'warehouse_ids'='null'::jsonb then null else warehouse_ids end where user_id=auth.uid();
  update public.user_invitations set status='accepted',accepted_at=now() where id=item.id;
  insert into public.stage_team_audit(actor,subject,action,changes)
    values(auth.uid(),auth.uid(),'invitation.accepted',
      jsonb_build_object('invitation_id',item.id,'system_admin',grant_admin));
  return true;
end;
$$;

commit;
