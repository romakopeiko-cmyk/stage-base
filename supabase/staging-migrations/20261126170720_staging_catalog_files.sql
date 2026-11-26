-- Stage Base Staging only.
begin;
alter table public.stage_catalog_permissions add column can_photo boolean not null default false,
  add column can_document boolean not null default false;
alter table public.user_invitations add column catalog_access jsonb;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values
 ('stage-catalog-photos','stage-catalog-photos',false,15728640,array['image/jpeg','image/png','image/webp']),
 ('stage-catalog-documents','stage-catalog-documents',false,52428800,array['application/pdf','application/zip','application/octet-stream',
 'application/vnd.openxmlformats-officedocument.wordprocessingml.document','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
 'model/gltf+json','model/gltf-binary','video/mp4','text/plain']);

create function public.stage_catalog_media_capabilities()
returns jsonb language sql stable security definer set search_path=''
as $$
  select jsonb_build_object(
    'photos', public.stage_member_active() and (coalesce((public.stage_team_capabilities()->>'delegate')::boolean,false)
      or coalesce((select can_photo from public.stage_catalog_permissions where user_id=auth.uid()),false)),
    'documents', public.stage_member_active() and (coalesce((public.stage_team_capabilities()->>'delegate')::boolean,false)
      or coalesce((select can_document from public.stage_catalog_permissions where user_id=auth.uid()),false))
  )
$$;

create policy stage_catalog_file_read on storage.objects for select to authenticated
using (bucket_id in ('stage-catalog-photos','stage-catalog-documents') and exists(
  select 1 from public.assets a
  where a.id::text=split_part(objects.name,'/',1) and not a.archived
    and public.stage_within_limits('assets.read',a.assigned_show_id,a.warehouse_id)
    and (public.can_read_asset(a.assigned_show_id,a.warehouse_id) or public.stage_has_individual_access())
));

create policy stage_catalog_file_insert on storage.objects for insert to authenticated
with check (
  ((bucket_id='stage-catalog-photos' and (public.stage_catalog_media_capabilities()->>'photos')::boolean)
    or (bucket_id='stage-catalog-documents' and (public.stage_catalog_media_capabilities()->>'documents')::boolean))
  and split_part(name,'/',2)=(select auth.uid())::text
  and name ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/[0-9a-f-]{36}-[^/]+$'
  and exists(select 1 from public.assets a
  where a.id::text=split_part(objects.name,'/',1) and not a.archived
    and public.stage_within_limits('assets.read',a.assigned_show_id,a.warehouse_id)
    and (public.can_read_asset(a.assigned_show_id,a.warehouse_id) or public.stage_has_individual_access()))
);

create function public.stage_catalog_list_files(p_asset uuid,p_before timestamptz default null)
returns table(bucket text,object_path text,uploaded_at timestamptz,uploaded_by uuid)
language sql stable security invoker set search_path=''
as $$
  select o.bucket_id,o.name,o.created_at,split_part(o.name,'/',2)::uuid
  from storage.objects o where o.bucket_id in ('stage-catalog-photos','stage-catalog-documents')
    and split_part(o.name,'/',1)=p_asset::text
    and (p_before is null or o.created_at<p_before)
  order by o.created_at desc,o.name limit 50
$$;

create function public.stage_save_member_catalog_permissions(
  p_user uuid,p_limits jsonb,p_create boolean,p_edit boolean,p_photo boolean,p_document boolean
) returns void language plpgsql security definer set search_path=''
as $$
declare previous jsonb;
begin
  if p_create is null or p_edit is null or p_photo is null or p_document is null then raise invalid_parameter_value; end if;
  perform public.stage_save_catalog_member_access(p_user,p_limits,p_create,p_edit);
  select to_jsonb(p) into previous from public.stage_catalog_permissions p where user_id=p_user;
  update public.stage_catalog_permissions set can_photo=p_photo,can_document=p_document where user_id=p_user;
  insert into public.stage_team_audit(actor,subject,action,changes) values(auth.uid(),p_user,'catalog.media.access.updated',
    jsonb_build_object('before',previous,'photos',p_photo,'documents',p_document));
end;
$$;

create function public.stage_prepare_catalog_invitation(
  p_email text,p_name text,p_job text,p_phone text,p_access jsonb,p_admin boolean,p_catalog_access jsonb
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare saved jsonb; flag text;
begin
  foreach flag in array array['can_create','can_edit','can_photo','can_document'] loop
    if jsonb_typeof(p_catalog_access->flag) is distinct from 'boolean' then raise invalid_parameter_value; end if;
  end loop;
  saved:=public.stage_prepare_contact_invitation(p_email,p_name,p_job,p_phone,p_access,p_admin);
  update public.user_invitations set catalog_access=p_catalog_access
    where id=(saved->>'id')::uuid and invited_by=auth.uid() and status='pending';
  insert into public.stage_team_audit(actor,subject,action,changes) values(auth.uid(),(saved->>'id')::uuid,
    'invitation.catalog.access',p_catalog_access);
  return saved;
end;
$$;

revoke execute on function public.stage_catalog_media_capabilities(),public.stage_catalog_list_files(uuid,timestamptz),
 public.stage_save_member_catalog_permissions(uuid,jsonb,boolean,boolean,boolean,boolean),
 public.stage_prepare_catalog_invitation(text,text,text,text,jsonb,boolean,jsonb) from public,anon,authenticated;
grant execute on function public.stage_catalog_media_capabilities(),public.stage_catalog_list_files(uuid,timestamptz),
 public.stage_save_member_catalog_permissions(uuid,jsonb,boolean,boolean,boolean,boolean),
 public.stage_prepare_catalog_invitation(text,text,text,text,jsonb,boolean,jsonb) to authenticated;
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
  if item.catalog_access is not null and exists (
    select 1 from public.profiles inviter join public.roles r on r.id=inviter.role_id
    where inviter.id=item.invited_by and inviter.is_admin and inviter.is_active
      and r.code in ('creative_producer','executive_producer')
  ) then
    insert into public.stage_catalog_permissions(user_id,can_create,can_edit,can_photo,can_document)
    values(auth.uid(),(item.catalog_access->>'can_create')::boolean,(item.catalog_access->>'can_edit')::boolean,
      (item.catalog_access->>'can_photo')::boolean,(item.catalog_access->>'can_document')::boolean);
  end if;
  update public.user_invitations set status='accepted',accepted_at=now() where id=item.id;
  insert into public.stage_team_audit(actor,subject,action,changes)
    values(auth.uid(),auth.uid(),'invitation.accepted',
      jsonb_build_object('invitation_id',item.id,'system_admin',grant_admin));
  return true;
end;
$$;

commit;
