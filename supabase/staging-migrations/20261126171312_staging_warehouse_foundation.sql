-- Stage Base Staging only. Operational tables remain closed until their RPCs are wired.
begin;
create table public.reservations (
  id uuid primary key default gen_random_uuid(),
  show_id uuid not null references public.shows(id),
  requested_by uuid not null references public.profiles(id),
  responsible_id uuid not null references public.profiles(id),
  start_date timestamptz not null,
  end_date timestamptz not null check (end_date > start_date),
  purpose text,
  status text not null default 'pending' check (status in ('pending','approved','rejected','issued','completed','cancelled')),
  approved_by uuid references public.profiles(id),
  approved_at timestamptz,
  rejection_reason text,
  updated_at timestamptz not null default now()
);
create table public.reservation_items (
  reservation_id uuid not null references public.reservations(id),
  asset_id uuid not null references public.assets(id),
  quantity numeric not null check (quantity>0 and quantity::text not in ('NaN','Infinity','-Infinity')),
  primary key (reservation_id,asset_id)
);
create table public.movements (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid references public.reservations(id),
  movement_type text not null check (movement_type in ('issue','return','transfer')),
  status text not null check (status in ('in_transit','received','completed')),
  from_show_id uuid references public.shows(id),
  to_show_id uuid references public.shows(id),
  from_warehouse_id uuid references public.warehouses(id),
  to_warehouse_id uuid references public.warehouses(id),
  created_by uuid not null references public.profiles(id),
  handed_over_by uuid references public.profiles(id),
  received_by uuid references public.profiles(id),
  approved_by uuid references public.profiles(id),
  approved_at timestamptz,
  dispatched_at timestamptz,
  received_at timestamptz,
  completed_at timestamptz,
  updated_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create table public.movement_items (
  id uuid primary key default gen_random_uuid(),
  movement_id uuid not null references public.movements(id),
  asset_id uuid not null references public.assets(id),
  quantity numeric not null check (quantity>0 and quantity::text not in ('NaN','Infinity','-Infinity')),
  condition_before text,
  comment text
);
create table public.inspections (
  id uuid primary key default gen_random_uuid(),
  asset_id uuid not null references public.assets(id),
  movement_item_id uuid references public.movement_items(id),
  assigned_to uuid references public.profiles(id),
  inspection_type text not null,
  status text not null default 'pending' check (status in ('pending','in_progress','completed')),
  received_at timestamptz,
  deadline_at timestamptz,
  deadline_changed_by uuid references public.profiles(id),
  deadline_change_reason text,
  condition_result text,
  completeness_confirmed boolean,
  inspected_by uuid references public.profiles(id),
  inspected_at timestamptz,
  comment text,
  emergency_release_by uuid references public.profiles(id),
  emergency_release_at timestamptz,
  emergency_release_reason text,
  updated_at timestamptz not null default now()
);
create table public.audit_log (
  id bigint generated always as identity primary key,
  actor_id uuid not null references public.profiles(id),
  action_type text not null,
  entity_type text not null,
  entity_id uuid not null,
  asset_id uuid references public.assets(id),
  show_id uuid references public.shows(id),
  warehouse_id uuid references public.warehouses(id),
  description text,
  created_at timestamptz not null default now()
);
create index staging_warehouse_reservation_show on public.reservations(show_id,start_date);
create index staging_warehouse_reservation_asset on public.reservation_items(asset_id,reservation_id);
create index staging_warehouse_movement_item on public.movement_items(movement_id,asset_id);
create index staging_warehouse_asset_inspection on public.inspections(asset_id,status);
alter table public.reservations enable row level security;
alter table public.reservation_items enable row level security;
alter table public.movements enable row level security;
alter table public.movement_items enable row level security;
alter table public.inspections enable row level security;
alter table public.audit_log enable row level security;
revoke all on public.reservations,public.reservation_items,public.movements,public.movement_items,public.inspections,public.audit_log
  from public,anon,authenticated;
commit;
