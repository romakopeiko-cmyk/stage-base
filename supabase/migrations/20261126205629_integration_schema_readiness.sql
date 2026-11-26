-- Public boolean handshake for the isolated Stage Base integration client.
begin;
create function public.stage_v1_integration_ready()
returns boolean language sql stable security invoker set search_path=''
as $$
  select to_regclass('public.categories') is not null
    and to_regclass('public.user_permissions') is not null
    and to_regclass('public.role_permissions') is not null
    and to_regclass('public.asset_documents') is not null
    and to_regclass('public.inspection_photos') is not null
    and exists (select 1 from pg_catalog.pg_attribute
      where attrelid=to_regclass('public.assets') and attname='qr_code' and not attisdropped)
    and not exists (
      select 1 from (values ('assets'),('profiles'),('stage_tasks'),('user_permissions'),('reservations'),('asset_documents')) required(name)
      left join pg_catalog.pg_class c on c.oid=to_regclass('public.'||required.name)
      where not coalesce(c.relrowsecurity,false)
    )
    and to_regprocedure('public.stage_v1_prepare_invitation(text,text,text,text,text[],uuid[],uuid[])') is not null
    and to_regprocedure('public.stage_v1_claim_invitation()') is not null
    and to_regprocedure('public.stage_list_reservations()') is not null
    and to_regprocedure('public.stage_list_stock()') is not null
    and to_regprocedure('public.stage_decide_team_task(bigint,boolean,text)') is not null
$$;
revoke execute on function public.stage_v1_integration_ready() from public,anon,authenticated;
grant execute on function public.stage_v1_integration_ready() to anon,authenticated;
commit;
