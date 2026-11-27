begin;
insert into auth.users(id,email) values
 ('00000000-0000-4000-8000-000000002001','creative@example.invalid'),
 ('00000000-0000-4000-8000-000000002002','clerk@example.invalid'),
 ('00000000-0000-4000-8000-000000002003','reader@example.invalid');
insert into public.roles(code,name) values ('creative_producer','Fixture creative'),('warehouse_manager','Fixture clerk'),('employee','Fixture reader');
insert into public.profiles(id,full_name,role_id,is_active)
select fixture.id::uuid,r.name,r.id,true from (values
 ('00000000-0000-4000-8000-000000002001','creative_producer'),
 ('00000000-0000-4000-8000-000000002002','warehouse_manager'),
 ('00000000-0000-4000-8000-000000002003','employee')) fixture(id,code) join public.roles r on r.code=fixture.code;
insert into public.permissions(code,name,module) values ('assets.view','View','assets'),('assets.create','Create','assets');
insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r cross join public.permissions p
where p.code='assets.view' or r.code='warehouse_manager';
insert into public.shows(id,name) values ('00000000-0000-4000-8000-000000002004','Fixture show');
insert into public.warehouses(id,name) values ('00000000-0000-4000-8000-000000002005','Fixture warehouse');
insert into stage_operations.import_batches(source_sha256,created_by)
values (repeat('a',64),'00000000-0000-4000-8000-000000002001');
insert into stage_operations.import_items(source_sha256,source_row,inventory_number,payload)
values (repeat('a',64),'Fixture:1','FIX-2001','{"name":"Fixture asset","show_hint":"Fixture show","quantity":null,"tracking_type":null,"original":{"cost":"never returned"}}');
set local role authenticated;
set local request.jwt.claim.sub='00000000-0000-4000-8000-000000002001';
do $$
declare record jsonb:=public.stage_import_catalog_page()->0;
begin
  if record->>'show_id' is distinct from '00000000-0000-4000-8000-000000002004'
     or record->>'quantity' is not null or record->>'tracking_type' is not null
     or record ? 'original' then raise exception 'Preview did not preserve source or privacy'; end if;
end;
$$;
set local request.jwt.claim.sub='00000000-0000-4000-8000-000000002003';
do $$ begin
  perform public.stage_import_catalog_page();
  raise exception 'Unauthorized intake visibility';
exception when insufficient_privilege then null; end $$;
set local request.jwt.claim.sub='00000000-0000-4000-8000-000000002002';
do $$
declare item bigint:=(public.stage_import_catalog_page()->0->>'import_id')::bigint;
warehouse constant uuid:='00000000-0000-4000-8000-000000002005';
show_id constant uuid:='00000000-0000-4000-8000-000000002004';
asset uuid;
begin
  asset:=public.stage_resolve_catalog_import(item,warehouse,'set',1,'компл.',show_id);
  if asset is null or asset is distinct from public.stage_resolve_catalog_import(item,warehouse,'set',1,'компл.',show_id)
     or jsonb_array_length(public.stage_import_catalog_page())<>0 then raise exception 'Import was not linked exactly once'; end if;
end;
$$;
reset role;
do $$ begin
 if not exists(select from public.assets where inventory_number='FIX-2001'
    and show_id='00000000-0000-4000-8000-000000002004' and condition='unverified' and tracking_type='set') then
    raise exception 'Incorrect final card';
 end if;
end $$;
rollback;
