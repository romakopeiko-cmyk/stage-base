-- Run after the migration as the database owner. No fixtures or writes.
do $$
declare
  client text;
  relation text;
  field text;
begin
  foreach client in array array['anon','authenticated'] loop
    foreach relation in array array[
      'access_grants','asset_events','asset_finance','asset_photos','assets',
      'notifications','profiles','roles','shows','user_show_access','warehouses'
    ] loop
      if has_table_privilege(client,'public.'||relation,'TRUNCATE, TRIGGER') then
        raise exception 'Excess table privilege on % for %',relation,client;
      end if;
    end loop;
    for field in select column_name from information_schema.columns
      where table_schema='public' and table_name='notifications'
    loop
      if has_column_privilege(client,'public.notifications',field,'UPDATE')
         is distinct from (client='authenticated' and field='is_read') then
        raise exception 'Unexpected notification write access on % for %',field,client;
      end if;
    end loop;
  end loop;
  if has_function_privilege('anon','public.can_read_asset(uuid,uuid)','EXECUTE')
     or not has_function_privilege('authenticated','public.can_read_asset(uuid,uuid)','EXECUTE') then
    raise exception 'Unexpected asset helper access';
  end if;
end;
$$;
