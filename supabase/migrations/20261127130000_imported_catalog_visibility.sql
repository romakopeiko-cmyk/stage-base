begin;

create function public.stage_import_catalog_page(p_after bigint default 0)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
  if coalesce(stage_operations.import_role(),'') not in ('executive_producer','creative_producer','warehouse_manager')
    or not public.has_permission('assets.view') then raise insufficient_privilege; end if;
  return coalesce((
    select jsonb_agg(to_jsonb(result) order by result.import_id)
    from (
      select i.id import_id,i.inventory_number,i.payload->>'name' name,
        i.payload->>'description' description,i.payload->>'comment' notes,
        i.payload->>'quantity' quantity,i.payload->>'unit' unit,i.payload->>'tracking_type' tracking_type,
        i.payload->>'show_hint' show_hint,i.payload->>'warehouse_hint' warehouse_hint,
        i.payload->>'category' category_hint,s.id show_id,c.id category_id
      from stage_operations.import_items i
      left join lateral (
        select (array_agg(id))[1] id from public.shows
        where lower(btrim(name))=lower(btrim(i.payload->>'show_hint')) having count(*)=1
      ) s on true
      left join lateral (
        select (array_agg(id))[1] id from public.categories
        where is_active and lower(btrim(name))=lower(btrim(i.payload->>'category')) having count(*)=1
      ) c on true
      where i.asset_id is null and i.id>greatest(coalesce(p_after,0),0)
        and (s.id is null or public.has_show_access(s.id))
        and not exists(select 1 from public.assets a where lower(btrim(a.inventory_number))=i.inventory_key)
      order by i.id limit 250
    ) result
  ),'[]'::jsonb);
end;
$$;
revoke execute on function public.stage_import_catalog_page(bigint) from public,anon,authenticated;
grant execute on function public.stage_import_catalog_page(bigint) to authenticated;

create function public.stage_resolve_catalog_import(
  p_item bigint,p_warehouse uuid,p_type text,p_quantity numeric,p_unit text,p_show uuid)
returns uuid language plpgsql security definer set search_path='' as $$
declare linked uuid; created uuid;
begin
  if coalesce(stage_operations.import_role(),'') not in ('executive_producer','warehouse_manager')
    or not public.has_permission('assets.create')
    or not public.has_warehouse_access(p_warehouse)
    or (p_show is not null and not public.has_show_access(p_show)) then raise insufficient_privilege; end if;
  select asset_id into linked from stage_operations.import_items where id=p_item for update;
  if linked is not null then return linked; end if;
  created:=stage_operations.resolve_import_item(p_item,p_warehouse,p_type,p_quantity,p_unit);
  if p_show is not null then update public.assets set show_id=p_show where id=created; end if;
  return created;
end;
$$;
revoke execute on function public.stage_resolve_catalog_import(bigint,uuid,text,numeric,text,uuid) from public,anon,authenticated;
grant execute on function public.stage_resolve_catalog_import(bigint,uuid,text,numeric,text,uuid) to authenticated;
commit;
