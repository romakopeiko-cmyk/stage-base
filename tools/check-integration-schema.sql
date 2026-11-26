-- Read-only. Run against the isolated test target before enabling the integration client.
with required_tables(name) as (values
  ('assets'),('asset_photos'),('asset_documents'),('categories'),('permissions'),
  ('role_permissions'),('user_permissions'),('user_warehouse_access'),('inspection_photos'),
  ('reservations'),('reservation_items'),('movements'),('movement_items'),('inspections'),
  ('stage_tasks'),('stage_task_history'),('profiles')),
required_columns(relation_name,column_name) as (values
  ('assets','category_id'),('assets','qr_code'),('assets','tracking_type'),('assets','location_type'),
  ('assets','show_id'),('assets','is_archived'),('assets','inspection_due_at'),('assets','physical_show_id'),
  ('stage_tasks','assigned_by'),('stage_tasks','show_id'),('profiles','contact_phone')),
required_functions(signature) as (values
  ('stage_list_reservations()'),('stage_list_stock()'),('stage_v1_claim_invitation()'),
  ('stage_v1_prepare_invitation(text,text,text,text,text[],uuid[],uuid[])'),
  ('stage_decide_team_task(bigint,boolean,text)'),('stage_v1_integration_ready()'))
select 'table' as kind, t.name as missing from required_tables t where to_regclass('public.'||t.name) is null
union all select 'rls', t.name from required_tables t join pg_class c on c.oid=to_regclass('public.'||t.name) where not c.relrowsecurity
union all select 'column', c.relation_name||'.'||c.column_name from required_columns c
where not exists(select 1 from pg_attribute a where a.attrelid=to_regclass('public.'||c.relation_name) and a.attname=c.column_name and not a.attisdropped)
union all select 'function', f.signature from required_functions f where to_regprocedure('public.'||f.signature) is null
order by 1,2;
