-- Run after the migration as the database owner. No fixtures or writes.
do $$
declare
  client text;
  relation record;
  field text;
begin
  foreach client in array array['anon','authenticated'] loop
    for relation in select n.nspname,c.relname from pg_class c
      join pg_namespace n on n.oid=c.relnamespace
      where n.nspname in ('public','stage_operations') and c.relkind in ('r','p')
    loop
      if has_table_privilege(client,format('%I.%I',relation.nspname,relation.relname),'TRUNCATE, TRIGGER') then
        raise exception 'Excess table privilege on %.% for %',relation.nspname,relation.relname,client;
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
