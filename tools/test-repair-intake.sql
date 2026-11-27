-- Run against an isolated canonical database after the repair migration.
begin;
insert into auth.users(id,email) values
 ('00000000-0000-4000-8000-000000001001','inventory@example.invalid'),
 ('00000000-0000-4000-8000-000000001002','reader@example.invalid');
insert into public.roles(code,name) values ('warehouse_manager','Test clerk'),('director','Test reader');
insert into public.profiles(id,full_name,role_id,is_active)
select '00000000-0000-4000-8000-000000001001','Test clerk',id,true from public.roles where code='warehouse_manager';
insert into public.profiles(id,full_name,role_id,is_active)
select '00000000-0000-4000-8000-000000001002','Test reader',id,true from public.roles where code='director';
insert into public.permissions(code,name,module)
select v,v,'repairs' from unnest(array['repairs.view','repairs.create','repairs.manage','repairs.complete','inspections.perform','assets.view']) as v;
insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r cross join public.permissions p
where r.code='warehouse_manager' or (r.code='director' and p.code in ('repairs.view','assets.view'));
insert into public.warehouses(id,name) values ('00000000-0000-4000-8000-000000001003','Inventory fixture warehouse');
insert into public.assets(id,name,inventory_number,qr_code,warehouse_id,condition,created_by)
values ('00000000-0000-4000-8000-000000001004','Inventory fixture asset','FIX-1004','FIX-QR',
 '00000000-0000-4000-8000-000000001003','good','00000000-0000-4000-8000-000000001001');

set local role authenticated;
set local request.jwt.claim.sub='00000000-0000-4000-8000-000000001001';
do $$
declare repair uuid; asset constant uuid:='00000000-0000-4000-8000-000000001004';
begin
  repair:=public.stage_report_repair(asset,'Пошкоджено опору',now()+interval '2 days',null);
  begin
    perform public.stage_report_repair(asset,'Повторна заявка',now()+interval '2 days',null);
    raise exception 'Duplicate repair';
  exception when unique_violation then null;
  end;
  begin
    perform public.stage_advance_repair(repair,'completed',null,null);
    raise exception 'Unchecked repair was completed';
  exception when invalid_parameter_value then null;
  end;
  perform public.stage_advance_repair(repair,'scheduled','Майстерня',null);
  perform public.stage_advance_repair(repair,'in_progress',null,null);
  perform public.stage_advance_repair(repair,'awaiting_inspection',null,'Замінено опору');
  begin
    perform public.stage_complete_repair(repair);
    raise exception 'Premature repair completion';
  exception when invalid_parameter_value then null;
  end;
  if public.stage_list_repairs()->'repairs'->0->>'status' is distinct from 'awaiting_inspection' then
    raise exception 'Repair was not sent for inspection';
  end if;
end;
$$;
reset role;
insert into storage.objects(bucket_id,name,created_at)
values ('asset-photos','00000000-0000-4000-8000-000000001004/fixture',now());
insert into public.asset_photos(asset_id,storage_path,uploaded_by)
values ('00000000-0000-4000-8000-000000001004','00000000-0000-4000-8000-000000001004/fixture',
 '00000000-0000-4000-8000-000000001001');
set local role authenticated;
select public.stage_finish_inspection('00000000-0000-4000-8000-000000001004','good',true,'Fixture','[]');
select public.stage_complete_repair((public.stage_list_repairs()->'repairs'->0->>'id')::uuid);
set local request.jwt.claim.sub='00000000-0000-4000-8000-000000001002';
do $$ begin
  if jsonb_array_length(public.stage_list_repairs()->'repairs')<>1 then raise exception 'Missing reader result'; end if;
  begin
    perform public.stage_advance_repair((public.stage_list_repairs()->'repairs'->0->>'id')::uuid,'completed',null,null);
    raise exception 'Reader changed repair';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
do $$ begin
  if not exists(select 1 from public.repairs r join public.repair_photos p on p.repair_id=r.id
      where r.status='completed' and p.photo_type='after') then raise exception 'Missing verified repair evidence'; end if;
  if (select count(*) from public.audit_log where entity_type='repair') <> 5 then raise exception 'Missing repair audit events'; end if;
end $$;
rollback;
