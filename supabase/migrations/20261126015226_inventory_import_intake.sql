begin;

create table stage_operations.import_batches (
  source_sha256 text primary key check (source_sha256 ~ '^[0-9a-f]{64}$'),
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);

create table stage_operations.import_items (
  id bigint generated always as identity primary key,
  source_sha256 text not null references stage_operations.import_batches,
  source_row text not null,
  inventory_number text not null,
  inventory_key text generated always as (lower(btrim(inventory_number))) stored unique,
  payload jsonb not null,
  asset_id uuid unique references public.assets(id),
  resolved_by uuid references public.profiles(id),
  resolved_at timestamptz,
  unique (source_sha256, source_row)
);

alter table stage_operations.import_batches enable row level security;
alter table stage_operations.import_items enable row level security;
revoke all on stage_operations.import_batches, stage_operations.import_items from public, anon, authenticated;

create function stage_operations.import_role()
returns text language sql stable security invoker set search_path = ''
as $$
  select r.code from public.profiles p join public.roles r on r.id = p.role_id
  where p.id = auth.uid() and p.is_active;
$$;

create function stage_operations.stage_import(source_hash text, items jsonb)
returns integer language plpgsql security definer set search_path = ''
as $$
declare
  imported_count integer;
begin
  if stage_operations.import_role() is distinct from 'executive_producer'
      or not public.has_permission('assets.create') or not public.has_permission('finance.edit') then
    raise exception 'Імпорт доступний виконавчому продюсеру' using errcode = '42501';
  end if;
  if source_hash is null or source_hash !~ '^[0-9a-f]{64}$'
      or jsonb_typeof(items) is distinct from 'array'
      or octet_length(items::text) > 4194304 then
    raise exception 'Некоректний пакет імпорту';
  end if;
  if jsonb_array_length(items) not between 1 and 2000 then
    raise exception 'Пакет повинен містити від 1 до 2000 позицій';
  end if;
  if exists (
    select 1 from jsonb_array_elements(items) row(value)
    where jsonb_typeof(value) <> 'object'
       or coalesce(length(btrim(value->>'source_row')), 0) not between 1 and 240
       or coalesce(length(btrim(value->>'inventory_number')), 0) not between 1 and 120
       or coalesce(length(btrim(value->>'name')), 0) not between 1 and 1000
       or ((value->>'original_number') is not null and value->>'original_number' <> value->>'inventory_number')
  ) then
    raise exception 'Перевірте назви, вихідні рядки та інвентарні номери';
  end if;

  insert into stage_operations.import_batches(source_sha256, created_by)
    values (source_hash, auth.uid())
    on conflict do nothing;
  if not found then
    raise exception 'Це джерело вже завантажено';
  end if;

  if exists (
    select 1 from jsonb_array_elements(items) row(value)
    join public.assets a on lower(btrim(a.inventory_number)) = lower(btrim(value->>'inventory_number'))
  ) then
    raise exception 'Пакет містить номер, який уже є в каталозі';
  end if;

  insert into stage_operations.import_items(source_sha256, source_row, inventory_number, payload)
  select source_hash, value->>'source_row', value->>'inventory_number', value
  from jsonb_array_elements(items) row(value)
  order by lower(btrim(value->>'inventory_number'));
  get diagnostics imported_count = row_count;
  return imported_count;
exception when unique_violation then
  raise exception 'Пакет містить повтор вихідного рядка або інвентарного номера';
end;
$$;

create function stage_operations.list_import_items(after_id bigint)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  if coalesce(stage_operations.import_role(), '') not in ('executive_producer','warehouse_manager')
      or not public.has_permission('assets.create') then
    raise exception 'Недостатньо прав' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(to_jsonb(result) order by result.id)
    from (
      select id, source_row, inventory_number, payload->>'name' as name,
        payload->>'warehouse_hint' as warehouse_hint, payload->>'quantity' as quantity_hint,
        payload->>'tracking_type' as tracking_hint, payload->>'category' as category_hint,
        payload->'review' as review
      from stage_operations.import_items
      where asset_id is null and id > coalesce(after_id, 0)
      order by id limit 50
    ) result
  ), '[]'::jsonb);
end;
$$;

create function stage_operations.resolve_import_item(
  item_id bigint, target_warehouse uuid, target_type text, target_quantity numeric, target_unit text
)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare
  candidate stage_operations.import_items%rowtype;
  created_asset uuid;
  matched_category uuid;
begin
  if coalesce(stage_operations.import_role(), '') not in ('executive_producer','warehouse_manager')
      or not public.has_permission('assets.create')
      or not public.has_warehouse_access(target_warehouse) then
    raise exception 'Недостатньо прав' using errcode = '42501';
  end if;
  if target_quantity is null or target_quantity::text in ('NaN','Infinity','-Infinity')
      or target_quantity <= 0 or target_type is null
      or target_type not in ('individual','set','consumable')
      or (target_type <> 'consumable' and target_quantity <> 1)
      or nullif(btrim(target_unit), '') is null
      or not exists (select 1 from public.warehouses where id = target_warehouse and is_active) then
    raise exception 'Підтвердьте склад, тип, кількість та одиницю';
  end if;

  select * into candidate from stage_operations.import_items where id = item_id for update;
  if not found then
    raise exception 'Позицію не знайдено';
  end if;
  if candidate.asset_id is not null then
    return candidate.asset_id;
  end if;

  -- Serialize the final normalized-number check with other catalog writes.
  lock table public.assets in share row exclusive mode;
  if exists (select 1 from public.assets where lower(btrim(inventory_number)) = candidate.inventory_key) then
    raise exception 'Цей інвентарний номер уже в каталозі';
  end if;

  select (array_agg(id))[1] into matched_category from public.categories
    where is_active and lower(name) = lower(candidate.payload->>'category')
    having count(*) = 1;

  insert into public.assets(inventory_number, name, description, notes, category_id,
    warehouse_id, tracking_type, quantity, unit, condition, location_type, created_by)
  values (candidate.inventory_number, candidate.payload->>'name',
    candidate.payload->>'description', candidate.payload->>'comment', matched_category,
    target_warehouse, target_type, target_quantity, btrim(target_unit), 'unverified', 'warehouse', auth.uid())
  returning id into created_asset;

  update stage_operations.import_items set asset_id = created_asset, resolved_by = auth.uid(), resolved_at = now()
  where id = item_id;
  return created_asset;
end;
$$;

-- Enforce inspection at the persistence boundary for future issue commands.
create table stage_operations.issue_exception_uses (
  inspection_id uuid primary key references public.inspections(id),
  movement_id uuid not null references public.movements(id)
);
alter table stage_operations.issue_exception_uses enable row level security;
revoke all on stage_operations.issue_exception_uses from public, anon, authenticated;

create function stage_operations.assert_issue_inspected(target_asset uuid, target_movement uuid)
returns void language plpgsql security invoker set search_path = ''
as $$
declare
  asset_condition text;
  exception_id uuid;
begin
  select condition into asset_condition from public.assets where id = target_asset for update;
  if not found then
    raise exception 'Майно не знайдено';
  end if;
  if asset_condition = 'unverified' then
    select i.id into exception_id from public.inspections i
    join public.profiles p on p.id = i.emergency_release_by
    join public.roles r on r.id = p.role_id
    where i.id = (
      select latest.id from public.inspections latest
      where latest.asset_id = target_asset and latest.status in ('pending','in_progress')
      order by latest.received_at desc, latest.id desc limit 1
    )
      and p.is_active and r.code = 'executive_producer'
      and i.emergency_release_at >= i.received_at and i.emergency_release_at <= now()
      and nullif(btrim(i.emergency_release_reason), '') is not null;
    if exception_id is null then
      raise exception 'Майно не перевірено. Видача заблокована';
    end if;

    insert into stage_operations.issue_exception_uses (inspection_id, movement_id)
      values (exception_id, target_movement)
      on conflict (inspection_id) do nothing;
    if not found and not exists (
      select 1 from stage_operations.issue_exception_uses
      where inspection_id = exception_id and movement_id = target_movement
    ) then
      raise exception 'Дозвіл на виняткову видачу вже використано';
    end if;
  end if;
end;
$$;

create function stage_operations.guard_issue()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  target uuid;
  movement_kind text;
begin
  if tg_table_name = 'movement_items' then
    select movement_type into movement_kind from public.movements where id = new.movement_id for update;
    if movement_kind = 'issue' then
      perform stage_operations.assert_issue_inspected(new.asset_id, new.movement_id);
    end if;
  elsif new.movement_type = 'issue' then
    for target in
      select distinct asset_id from public.movement_items where movement_id = new.id order by asset_id
    loop
      perform stage_operations.assert_issue_inspected(target, new.id);
    end loop;
  end if;
  return new;
end;
$$;

create trigger stage_issue_item_requires_inspection
before insert or update of asset_id, movement_id on public.movement_items
for each row execute function stage_operations.guard_issue();

create trigger stage_issue_movement_requires_inspection
before update of movement_type, status, dispatched_at on public.movements
for each row execute function stage_operations.guard_issue();

revoke execute on function stage_operations.guard_issue(),stage_operations.assert_issue_inspected(uuid,uuid)
from public, anon, authenticated;

create function public.stage_import_inventory(p_source_hash text, p_items jsonb)
returns integer language sql security invoker set search_path = ''
as $$ select stage_operations.stage_import(p_source_hash,p_items); $$;

create function public.stage_list_import_items(p_after bigint)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select stage_operations.list_import_items(p_after); $$;

create function public.stage_resolve_import_item(p_item bigint,p_warehouse uuid,p_type text,p_quantity numeric,p_unit text)
returns uuid language sql security invoker set search_path = ''
as $$ select stage_operations.resolve_import_item(p_item,p_warehouse,p_type,p_quantity,p_unit); $$;

revoke execute on function stage_operations.import_role(),
  stage_operations.stage_import(text,jsonb), stage_operations.list_import_items(bigint),
  stage_operations.resolve_import_item(bigint,uuid,text,numeric,text),
  public.stage_import_inventory(text,jsonb), public.stage_list_import_items(bigint),
  public.stage_resolve_import_item(bigint,uuid,text,numeric,text) from public, anon, authenticated;

grant execute on function stage_operations.stage_import(text,jsonb), stage_operations.list_import_items(bigint),
  stage_operations.resolve_import_item(bigint,uuid,text,numeric,text),
  public.stage_import_inventory(text,jsonb), public.stage_list_import_items(bigint),
  public.stage_resolve_import_item(bigint,uuid,text,numeric,text) to authenticated;

commit;
