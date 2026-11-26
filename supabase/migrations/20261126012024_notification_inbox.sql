begin;

alter table public.notifications enable row level security;

create index notifications_recipient_created_idx
  on public.notifications (recipient_id, created_at desc, id desc);

grant select (id, title, message, created_at, is_read, read_at)
  on public.notifications to authenticated;
grant update (is_read) on public.notifications to authenticated;

create policy notifications_select_recipient on public.notifications
  for select to authenticated
  using (
    recipient_id = (select auth.uid())
    and exists (
      select 1 from public.profiles
      where id = (select auth.uid()) and is_active
    )
  );

create policy notifications_mark_read on public.notifications
  for update to authenticated
  using (
    recipient_id = (select auth.uid())
    and not is_read
    and exists (
      select 1 from public.profiles
      where id = (select auth.uid()) and is_active
    )
  )
  with check (
    recipient_id = (select auth.uid())
    and is_read
    and exists (
      select 1 from public.profiles
      where id = (select auth.uid()) and is_active
    )
  );

create function public.stage_notification_read_at()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.is_read and not old.is_read then
    new.read_at := statement_timestamp();
  end if;
  return new;
end;
$$;

revoke execute on function public.stage_notification_read_at() from public, anon, authenticated;

create trigger stage_notification_read_at
  before update of is_read on public.notifications
  for each row execute function public.stage_notification_read_at();

commit;
