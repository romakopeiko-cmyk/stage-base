-- Stage Base Staging only. The production permission matrix needs its own integration.
begin;
alter table public.user_invitations add column full_name text, add column last_attempt_at timestamptz;
revoke all on public.user_invitations from anon,authenticated;
create unique index stage_pending_invitation on public.user_invitations(lower(email)) where status='pending';

create function public.stage_member_active()
returns boolean language sql stable security definer set search_path=''
as $$ select exists(select 1 from public.profiles where id=auth.uid() and is_active) $$;
revoke execute on function public.stage_member_active() from public,anon;
grant execute on function public.stage_member_active() to authenticated;

-- Apply the active check even when a valid JWT predates deactivation.
do $$
declare t text;
begin
  foreach t in array array['shows','warehouses','assets','asset_photos','asset_events','asset_finance','access_grants',
    'stage_tasks','stage_task_comments','stage_task_steps','stage_task_history','notifications']
  loop
    execute format('create policy staging_active_member on public.%I as restrictive for all to authenticated using ((select public.stage_member_active())) with check ((select public.stage_member_active()))',t);
  end loop;
end $$;
create policy staging_active_private_files on storage.objects as restrictive for all to authenticated
using ((select public.stage_member_active())) with check ((select public.stage_member_active()));

-- Opt-out of signed object URLs in the staging client. Use authenticated downloads.
create function public.stage_team_invitations()
returns jsonb language plpgsql stable security definer set search_path=''
as $$
begin
  if not (public.stage_team_capabilities()->>'manage')::boolean then raise insufficient_privilege; end if;
  return (select coalesce(jsonb_agg(to_jsonb(i)), '[]') from
    (select id,email,full_name,role_id,status,expires_at from public.user_invitations order by created_at desc limit 100) i);
end;
$$;

create function public.stage_team_invitation_action(p_action text,p_id uuid,p_email text,p_name text,p_role uuid)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare item public.user_invitations%rowtype; code text;
begin
  perform pg_catalog.pg_advisory_xact_lock(708217955);
  if not (public.stage_team_capabilities()->>'delegate')::boolean then raise insufficient_privilege; end if;
  if p_action='invite' then
    p_email:=lower(btrim(p_email));
    select r.code into code from public.roles r where r.id=p_role;
    if code is null or code in ('executive_producer','creative_producer') or
      coalesce(length(btrim(p_name)),0) not between 1 and 120 or
      coalesce(length(p_email),0) not between 3 and 254 or p_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
      raise exception 'Перевірте ім’я, адресу та роль' using errcode='22023';
    end if;
    if exists(select 1 from auth.users u join public.profiles p on p.id=u.id where lower(u.email)=p_email) then
      raise exception 'Працівник уже зареєстрований' using errcode='23505';
    end if;
    insert into public.user_invitations(email,full_name,role_id,invited_by,status,expires_at,last_attempt_at)
      values(p_email,btrim(p_name),p_role,auth.uid(),'pending',now()+interval '7 days',now()) returning * into item;
  elsif p_action in ('resend','revoke') then
    select * into item from public.user_invitations where id=p_id and status='pending' for update;
    if not found then raise exception 'Запрошення вже закрито' using errcode='22023'; end if;
    if p_action='resend' and item.last_attempt_at > now()-interval '60 seconds' then
      raise exception 'Зачекайте хвилину перед повторним надсиланням' using errcode='22023';
    end if;
    update public.user_invitations set status=case when p_action='revoke' then 'revoked' else status end,
      expires_at=case when p_action='resend' then now()+interval '7 days' else expires_at end,
      last_attempt_at=case when p_action='resend' then now() else last_attempt_at end
      where id=item.id returning * into item;
  else
    raise exception 'Невідома дія' using errcode='22023';
  end if;
  insert into public.stage_team_audit(actor,subject,action,changes)
    values(auth.uid(),item.id,'invitation.'||p_action,jsonb_build_object('status',item.status));
  return jsonb_build_object('id',item.id,'email',item.email);
end;
$$;

create function public.stage_claim_team_invitation()
returns boolean language plpgsql security definer set search_path=''
as $$
declare item public.user_invitations%rowtype; email_address text; role_code text;
begin
  perform pg_catalog.pg_advisory_xact_lock(708217955);
  if exists(select 1 from public.profiles where id=auth.uid()) then return false; end if;
  select lower(email) into email_address from auth.users where id=auth.uid() and email_confirmed_at is not null;
  if email_address is null then return false; end if;
  select * into item from public.user_invitations where lower(email)=email_address
    and status='pending' and expires_at>now() for update;
  if not found then return false; end if;
  select code into role_code from public.roles where id=item.role_id;
  if role_code is null or role_code in ('executive_producer','creative_producer') then return false; end if;
  insert into public.profiles(id,display_name,role,active,full_name,role_id,is_active,is_admin)
    values(auth.uid(),item.full_name,case role_code when 'line_producer' then 'show_producer'
      when 'employee' then 'staff' else role_code end,true,item.full_name,item.role_id,true,false);
  update public.user_invitations set status='accepted',accepted_at=now() where id=item.id;
  return true;
end;
$$;

create function public.stage_team_transfer_tasks(p_from uuid,p_to uuid)
returns integer language plpgsql security definer set search_path=''
as $$
declare changed int;
begin
  perform pg_catalog.pg_advisory_xact_lock(708217955);
  if not (public.stage_team_capabilities()->>'delegate')::boolean then raise insufficient_privilege; end if;
  if p_from=p_to or not exists(select 1 from public.profiles where id=p_to and is_active) then
    raise exception 'Оберіть іншого активного працівника' using errcode='22023';
  end if;
  -- Keep the original author, completed history, and any task bound to a warehouse workflow.
  update public.stage_tasks t set owner_id=p_to
    where t.owner_id=p_from and t.assigned_by is not null and t.status in ('planned','todo','doing','blocked')
      and public.has_show_access(t.show_id)
      and (exists(select 1 from public.user_show_access a where a.user_id=p_to and a.show_id=t.show_id)
        or exists(select 1 from public.profiles p join public.roles r on r.id=p.role_id where p.id=p_to
          and r.code in ('executive_producer','creative_producer','warehouse_manager','director','finance_director')));
  get diagnostics changed = row_count;
  insert into public.stage_team_audit(actor,subject,action,changes) values
    (auth.uid(),p_to,'tasks.transferred',jsonb_build_object('from',p_from,'count',changed));
  return changed;
end;
$$;

revoke execute on function public.stage_team_invitation_action(text,uuid,text,text,uuid),
  public.stage_team_invitations(),public.stage_claim_team_invitation(),public.stage_team_transfer_tasks(uuid,uuid)
  from public,anon,authenticated;
grant execute on function public.stage_team_invitation_action(text,uuid,text,text,uuid),
  public.stage_team_invitations(),public.stage_claim_team_invitation(),public.stage_team_transfer_tasks(uuid,uuid) to authenticated;
commit;
