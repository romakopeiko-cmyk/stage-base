-- Stage Base: foundation only. Apply to a new Supabase project after review.
begin;
create table public.shows (
 id uuid primary key default gen_random_uuid(), name text not null unique,
 status text not null default 'active' check(status in ('active','paused','archived'))
);
create table public.warehouses (
 id uuid primary key default gen_random_uuid(), name text not null unique
);
create table public.profiles (
 id uuid primary key references auth.users(id), display_name text not null,
 role text not null check(role in ('head_producer','creative_producer','director','finance_director','warehouse_manager','show_producer','show_admin','staff')),
 active boolean not null default false, is_admin boolean not null default false
);
create table public.access_grants (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references public.profiles(id),
 permission text not null, show_id uuid references public.shows(id), warehouse_id uuid references public.warehouses(id)
);
create table public.assets (
 id uuid primary key default gen_random_uuid(), inventory_number text not null unique,
 name text not null, category text, subcategory text, tags text[] not null default '{}',
 original_show_id uuid references public.shows(id), assigned_show_id uuid references public.shows(id),
 warehouse_id uuid references public.warehouses(id), location_kind text not null default 'warehouse'
 check(location_kind in ('warehouse','project','transit','contractor','workshop','repair','temporary_storage')),
 location_detail text, responsible_id uuid references public.profiles(id),
 tracking_kind text not null default 'individual' check(tracking_kind in ('individual','set','consumable')),
 quantity numeric not null default 1 check(quantity>=0), unit text not null default 'шт.',
 verified boolean not null default false, condition text not null default 'unassessed'
 check(condition in ('unassessed','serviceable','repair_needed','irreparable')),
 inspection_due timestamptz, color text, material text, width_cm numeric, height_cm numeric, depth_cm numeric, weight_kg numeric,
 disassembled_dimensions text, completeness jsonb not null default '[]', notes text, archived boolean not null default false,
 last_used_at timestamptz, created_at timestamptz not null default now(),
 check(tracking_kind='consumable' or quantity=1)
);
create table public.asset_finance (
 asset_id uuid primary key references public.assets(id), replacement_value numeric check(replacement_value>=0),
 currency text not null default 'UAH'
);
create table public.asset_events (
 id bigint generated always as identity primary key, asset_id uuid not null references public.assets(id),
 actor_id uuid not null references public.profiles(id), event_type text not null,
 details jsonb not null default '{}', created_at timestamptz not null default now()
);
create table public.asset_photos (
 id uuid primary key default gen_random_uuid(), asset_id uuid not null references public.assets(id),
 object_path text not null unique, event_id bigint references public.asset_events(id),
 uploaded_by uuid not null references public.profiles(id), created_at timestamptz not null default now()
);
-- Deny by default. No direct client writes until transactional RPCs are implemented.
alter table public.shows enable row level security;
alter table public.warehouses enable row level security;
alter table public.profiles enable row level security;
alter table public.access_grants enable row level security;
alter table public.assets enable row level security;
alter table public.asset_finance enable row level security;
alter table public.asset_events enable row level security;
alter table public.asset_photos enable row level security;
create policy profile_self on public.profiles for select to authenticated using(id=auth.uid());
create policy grants_self on public.access_grants for select to authenticated using(user_id=auth.uid());
create function public.can_read_asset(s uuid,w uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.profiles p where p.id=auth.uid() and p.active and
 (p.is_admin or p.role in ('director','finance_director') or exists(
 select 1 from public.access_grants g where g.user_id=p.id and g.permission='asset.read'
 and (g.show_id is null or g.show_id=s) and (g.warehouse_id is null or g.warehouse_id=w))))
$$;
revoke all on function public.can_read_asset(uuid,uuid) from public;
grant execute on function public.can_read_asset(uuid,uuid) to authenticated;
create policy assets_read on public.assets for select to authenticated using(public.can_read_asset(assigned_show_id,warehouse_id));
create policy shows_read on public.shows for select to authenticated using(exists(select 1 from public.profiles p where p.id=auth.uid() and p.active));
create policy warehouses_read on public.warehouses for select to authenticated using(exists(select 1 from public.profiles p where p.id=auth.uid() and p.active));
create policy finance_read on public.asset_finance for select to authenticated using(exists(
 select 1 from public.profiles p join public.assets a on a.id=asset_id where p.id=auth.uid() and p.active
 and (p.role in ('head_producer','creative_producer','director','finance_director') or
 (p.role='show_producer' and exists(select 1 from public.access_grants g where g.user_id=p.id and g.permission='finance.read' and g.show_id=a.assigned_show_id)))));
create policy events_read on public.asset_events for select to authenticated using(exists(select 1 from public.assets a where a.id=asset_id));
create policy photos_read on public.asset_photos for select to authenticated using(exists(select 1 from public.assets a where a.id=asset_id));
-- Private storage; no client object access until scoped storage policies are added.
insert into storage.buckets(id,name,public) values ('asset-photos','asset-photos',false) on conflict(id) do nothing;
insert into public.warehouses(name) values ('ВДНГ'),('FILM.UA');
commit;
