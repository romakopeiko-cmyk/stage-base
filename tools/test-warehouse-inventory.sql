-- Run against an isolated canonical database after the inventory migration.
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
select v,v,'inventory' from unnest(array['inventory.view','inventory.create','inventory.perform','inventory.complete','assets.view']) as v;
insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r cross join public.permissions p
where r.code='warehouse_manager' or (r.code='director' and p.code in ('inventory.view','assets.view'));
insert into public.warehouses(id,name) values ('00000000-0000-4000-8000-000000001003','Inventory fixture warehouse');
insert into public.assets(id,name,inventory_number,qr_code,warehouse_id,condition,created_by)
values ('00000000-0000-4000-8000-000000001004','Inventory fixture asset','FIX-1004','FIX-QR',
 '00000000-0000-4000-8000-000000001003','good','00000000-0000-4000-8000-000000001001');

set local role authenticated;
set local request.jwt.claim.sub='00000000-0000-4000-8000-000000001001';
do $$
declare session_id uuid; item_id uuid; result jsonb;
begin
  session_id:=public.stage_start_warehouse_inventory('00000000-0000-4000-8000-000000001003','Test count');
  result:=public.stage_warehouse_inventory(session_id);
  item_id:=(result->'items'->0->>'id')::uuid;
  if item_id is null or result->'items'->0->>'expected'<>'1.000' then raise exception 'Snapshot mismatch'; end if;
  begin
    perform public.stage_complete_warehouse_inventory(session_id);
    raise exception 'Pending count was completed';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.stage_record_warehouse_count(session_id,item_id,'wrong label',1);
    raise exception 'Wrong QR accepted';
  exception when invalid_parameter_value then null;
  end;
  perform public.stage_record_warehouse_count(session_id,item_id,'',0);
  if public.stage_warehouse_inventory(session_id)->'items'->0->>'status'<>'missing' then raise exception 'Missing item was not marked'; end if;
  perform public.stage_complete_warehouse_inventory(session_id);
  if public.stage_warehouse_inventory(session_id)->'sessions'->0->>'status'<>'completed' then raise exception 'Session not completed'; end if;
end;
$$;
set local request.jwt.claim.sub='00000000-0000-4000-8000-000000001002';
do $$ begin
  if jsonb_array_length(public.stage_warehouse_inventory()->'sessions')<>1 then raise exception 'Reader could not list inventory'; end if;
  begin
    perform public.stage_start_warehouse_inventory('00000000-0000-4000-8000-000000001003','Denied');
    raise exception 'Reader created inventory';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
do $$ begin
  if not exists(select 1 from public.assets where id='00000000-0000-4000-8000-000000001004' and not is_archived and quantity=1) then
    raise exception 'Inventory count changed stock';
  end if;
end $$;
rollback;
