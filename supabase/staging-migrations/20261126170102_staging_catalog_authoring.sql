-- Stage Base Staging only. Catalog edits preserve location, quantity and verification.
begin;
create table public.stage_catalog_permissions (
  user_id uuid primary key references public.profiles(id),
  can_create boolean not null default false,
  can_edit boolean not null default false
);
alter table public.stage_catalog_permissions enable row level security;
revoke all on public.stage_catalog_permissions from public,anon,authenticated;
create sequence public.stage_catalog_inventory_number;

create function public.stage_catalog_capabilities()
returns jsonb language sql stable security definer set search_path=''
as $$
  select jsonb_build_object(
    'create',public.stage_member_active() and (coalesce((public.stage_team_capabilities()->>'delegate')::boolean,false) or coalesce((select can_create from public.stage_catalog_permissions where user_id=auth.uid()),false)),
    'edit',public.stage_member_active() and (coalesce((public.stage_team_capabilities()->>'delegate')::boolean,false) or coalesce((select can_edit from public.stage_catalog_permissions where user_id=auth.uid()),false))
  )
$$;

create function public.stage_catalog_permissions_for(p_user uuid,p_create boolean default null,p_edit boolean default null)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare previous jsonb;
begin
  perform pg_catalog.pg_advisory_xact_lock(708217955);
  if not coalesce((public.stage_team_capabilities()->>'delegate')::boolean,false)
    or p_user=auth.uid() or not exists(select 1 from public.profiles p where p.id=p_user and not p.is_admin) then
    raise insufficient_privilege;
  end if;
  select to_jsonb(x) into previous from public.stage_catalog_permissions x where user_id=p_user;
  if p_create is not null and p_edit is not null then
    insert into public.stage_catalog_permissions values(p_user,p_create,p_edit)
    on conflict(user_id) do update set can_create=excluded.can_create,can_edit=excluded.can_edit;
    insert into public.stage_team_audit(actor,subject,action,changes) values(auth.uid(),p_user,'catalog.access.updated',
      jsonb_build_object('before',previous,'create',p_create,'edit',p_edit));
  end if;
  return coalesce((select to_jsonb(x) from public.stage_catalog_permissions x where user_id=p_user),
                  '{"can_create":false,"can_edit":false}'::jsonb);
end;
$$;

create function public.stage_catalog_save(p_asset uuid, p_name text, p_category text, p_color text, p_material text,
  p_notes text,p_show uuid default null,p_warehouse uuid default null,p_tracking text default 'individual',
  p_quantity numeric default 1,p_unit text default 'шт.')
returns uuid language plpgsql security definer set search_path=''
as $$
declare item public.assets%rowtype; asset_number text; rights jsonb;
begin
  perform pg_catalog.pg_advisory_xact_lock(708217955);
  rights:=public.stage_catalog_capabilities();
  if not ((rights->>case when p_asset is null then 'create' else 'edit' end)::boolean) then raise insufficient_privilege; end if;
  if coalesce(length(btrim(p_name)),0) not between 1 and 180 or
    length(coalesce(p_category,''))>120 or length(coalesce(p_color,''))>80
    or length(coalesce(p_material,''))>120 or length(coalesce(p_notes,''))>4000 then
    raise exception 'Перевірте назву й характеристики' using errcode='22023';
  end if;
  if p_asset is null then
    if p_warehouse is null or not exists(select 1 from public.warehouses where id=p_warehouse)
      or (p_show is not null and not exists(select 1 from public.shows where id=p_show))
      or p_tracking is null or p_tracking not in ('individual','set','consumable')
      or p_quantity is null or p_quantity<=0 or p_quantity>100000000
      or (p_tracking<>'consumable' and p_quantity<>1)
      or coalesce(length(btrim(p_unit)),0) not between 1 and 24 then
      raise exception 'Перевірте склад, шоу, тип обліку та кількість' using errcode='22023';
    end if;
    if not public.stage_within_limits('assets.read',p_show,p_warehouse) then raise insufficient_privilege; end if;
    loop
      asset_number:='SB-STG-'||nextval('public.stage_catalog_inventory_number'::regclass)::text;
      insert into public.assets(inventory_number,name,category,color,material,notes,original_show_id,assigned_show_id,warehouse_id,
        tracking_kind,quantity,unit,verified,condition)
      values(asset_number,btrim(p_name),nullif(btrim(p_category),''),nullif(btrim(p_color),''),
        nullif(btrim(p_material),''),nullif(btrim(p_notes),''),p_show,p_show,p_warehouse,p_tracking,
        p_quantity,btrim(p_unit),false,'unassessed')
      on conflict (inventory_number) do nothing returning id into p_asset;
      exit when found;
    end loop;
  else
    select * into item from public.assets where id=p_asset and not archived for update;
    if not found or not public.stage_within_limits('assets.read',item.assigned_show_id,item.warehouse_id)
      or not (public.can_read_asset(item.assigned_show_id,item.warehouse_id)
              or public.stage_has_individual_access()) then raise insufficient_privilege; end if;
    update public.assets set name=btrim(p_name),category=nullif(btrim(p_category),''),color=nullif(btrim(p_color),''),
      material=nullif(btrim(p_material),''),notes=nullif(btrim(p_notes),'') where id=p_asset;
  end if;
  insert into public.asset_events(asset_id,actor_id,event_type,details)
    select id,auth.uid(),case when item.id is null then 'catalog.created' else 'catalog.updated' end,
      jsonb_build_object('before',case when item.id is not null then jsonb_build_object('name',item.name,'category',item.category,'color',item.color,'material',item.material,'notes',item.notes) end,
        'after',jsonb_build_object('name',name,'category',category,'color',color,'material',material,'notes',notes))
    from public.assets where id=p_asset;
  return p_asset;
end;
$$;
revoke execute on function public.stage_catalog_capabilities(),public.stage_catalog_permissions_for(uuid,boolean,boolean),
  public.stage_catalog_save(uuid,text,text,text,text,text,uuid,uuid,text,numeric,text) from public,anon,authenticated;
grant execute on function public.stage_catalog_capabilities(),public.stage_catalog_permissions_for(uuid,boolean,boolean),
  public.stage_catalog_save(uuid,text,text,text,text,text,uuid,uuid,text,numeric,text) to authenticated;
create function public.stage_save_catalog_member_access(p_user uuid,p_limits jsonb,p_create boolean,p_edit boolean)
returns void language plpgsql security invoker set search_path=''
as $$
begin
  perform public.stage_team_limits(p_user,p_limits);
  perform public.stage_catalog_permissions_for(p_user,p_create,p_edit);
end;
$$;
revoke execute on function public.stage_save_catalog_member_access(uuid,jsonb,boolean,boolean) from public,anon,authenticated;
grant execute on function public.stage_save_catalog_member_access(uuid,jsonb,boolean,boolean) to authenticated;
commit;
