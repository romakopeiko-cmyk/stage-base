begin;
create table stage_operations.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id),
  endpoint text not null unique,
  p256dh text not null,
  auth_key text not null,
  enabled boolean not null default true
);
create index push_active_user_idx on stage_operations.push_subscriptions(user_id) where enabled;

create table stage_operations.push_jobs (
  id bigint generated always as identity primary key,
  notification_id uuid not null references public.notifications(id),
  subscription_id uuid not null references stage_operations.push_subscriptions(id),
  due_at timestamptz not null default now(),
  attempts integer not null default 0,
  lease uuid,
  delivered_at timestamptz,
  failed_at timestamptz,
  unique(notification_id, subscription_id)
);
create index push_due_idx on stage_operations.push_jobs(due_at,id)
  where delivered_at is null and failed_at is null;
alter table stage_operations.push_subscriptions enable row level security;
alter table stage_operations.push_jobs enable row level security;
revoke all on stage_operations.push_subscriptions, stage_operations.push_jobs from public, anon, authenticated;

create function stage_operations.register_push(p_endpoint text,p_key text,p_auth text)
returns void language plpgsql security definer set search_path=''
as $$
begin
  if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and is_active) then
    raise exception 'Недостатньо прав' using errcode='42501';
  end if;
  if p_endpoint is null or length(p_endpoint)>1800
      or p_endpoint !~ '^https://(web[.]push[.]apple[.]com|fcm[.]googleapis[.]com|updates[.]push[.]services[.]mozilla[.]com)/[^[:space:]#]+$'
      or p_key is null or p_key !~ '^[A-Za-z0-9_-]{87}$'
      or p_auth is null or p_auth !~ '^[A-Za-z0-9_-]{22}$' then
    raise exception 'Некоректна або непідтримувана підписка';
  end if;
  insert into stage_operations.push_subscriptions(user_id,endpoint,p256dh,auth_key)
  values(auth.uid(),p_endpoint,p_key,p_auth)
  on conflict(endpoint) do update set p256dh=excluded.p256dh,auth_key=excluded.auth_key,enabled=true
  where push_subscriptions.user_id=excluded.user_id;
  if not found then raise exception 'Ця підписка прив’язана до іншого облікового запису'; end if;
end;
$$;

create function stage_operations.disable_push(p_endpoint text)
returns void language sql security definer set search_path=''
as $$ update stage_operations.push_subscriptions set enabled=false
 where auth.uid() is not null and user_id=auth.uid() and endpoint=p_endpoint; $$;

create function stage_operations.enqueue_push()
returns trigger language plpgsql security definer set search_path=''
as $$
begin
  insert into stage_operations.push_jobs(notification_id,subscription_id)
    select new.id,id from stage_operations.push_subscriptions where user_id=new.recipient_id and enabled
    on conflict do nothing;
  return new;
end;
$$;
create trigger stage_push_on_notification after insert on public.notifications
for each row execute function stage_operations.enqueue_push();

create function public.stage_register_push(p_endpoint text,p_key text,p_auth text)
returns void language sql security invoker set search_path=''
as $$ select stage_operations.register_push(p_endpoint,p_key,p_auth); $$;
create function public.stage_disable_push(p_endpoint text)
returns void language sql security invoker set search_path=''
as $$ select stage_operations.disable_push(p_endpoint); $$;

create function public.stage_claim_push()
returns table(job_id bigint, lease uuid, endpoint text, p256dh text, auth_key text)
language sql security definer set search_path=''
as $$
  with expired_lease as (
    update stage_operations.push_jobs set failed_at=now(),lease=null
    where due_at<=now() and attempts>=5 and delivered_at is null and failed_at is null
  ), picked as (
    select j.id from stage_operations.push_jobs j
    join stage_operations.push_subscriptions s on s.id=j.subscription_id and s.enabled
    join public.profiles p on p.id=s.user_id and p.is_active
    join public.notifications n on n.id=j.notification_id and n.recipient_id=s.user_id and not n.is_read
    where j.due_at<=now() and j.delivered_at is null and j.failed_at is null and j.attempts<5
    order by j.due_at,j.id limit 20 for update of j skip locked
  ), claimed as (
    update stage_operations.push_jobs j
    set lease=gen_random_uuid(),attempts=attempts+1,due_at=now()+interval '5 minutes'
    from picked where j.id=picked.id returning j.*
  )
  select c.id,c.lease,s.endpoint,s.p256dh,s.auth_key from claimed c
  join stage_operations.push_subscriptions s on s.id=c.subscription_id;
$$;

create function public.stage_finish_push(p_job bigint,p_lease uuid,p_result text)
returns void language plpgsql security definer set search_path=''
as $$
declare target uuid;
begin
  if p_result is null or p_result not in ('delivered','expired','retry','failed') then
    raise exception 'Invalid result';
  end if;
  update stage_operations.push_jobs set lease=null,
    delivered_at=case when p_result='delivered' then now() end,
    failed_at=case when p_result in ('expired','failed') or (p_result='retry' and attempts>=5) then now() end,
    due_at=now()+make_interval(mins=>attempts*2)
  where id=p_job and lease=p_lease and p_lease is not null returning subscription_id into target;
  if p_result='expired' and target is not null then
    update stage_operations.push_subscriptions set enabled=false where id=target;
  end if;
end;
$$;

revoke execute on function stage_operations.register_push(text,text,text),stage_operations.disable_push(text),
 stage_operations.enqueue_push(),public.stage_register_push(text,text,text),public.stage_disable_push(text),
 public.stage_claim_push(),public.stage_finish_push(bigint,uuid,text) from public,anon,authenticated;
grant execute on function stage_operations.register_push(text,text,text),stage_operations.disable_push(text),
 public.stage_register_push(text,text,text),public.stage_disable_push(text) to authenticated;
grant execute on function public.stage_claim_push(),public.stage_finish_push(bigint,uuid,text) to service_role;
commit;
