CREATE SCHEMA IF NOT EXISTS stage_private;
REVOKE ALL ON SCHEMA stage_private FROM PUBLIC, anon, authenticated;
ALTER TABLE public.assets ALTER COLUMN created_by SET DEFAULT auth.uid();
REVOKE INSERT, UPDATE, DELETE ON public.assets FROM PUBLIC, anon, authenticated;
GRANT INSERT (inventory_number,name,description,category_id,original_show_id,show_id,warehouse_id,tracking_type,quantity,unit,color,material,width_cm,height_cm,depth_cm,weight_kg,disassembled_dimensions,storage_address,tags,notes,is_marketing_asset) ON public.assets TO authenticated;
GRANT UPDATE (name,description,category_id,color,material,width_cm,height_cm,depth_cm,weight_kg,disassembled_dimensions,tags,notes) ON public.assets TO authenticated;
CREATE POLICY assets_insert ON public.assets FOR INSERT TO authenticated WITH CHECK (
 public.has_permission('assets.create') AND public.has_permission('assets.view')
 AND created_by=auth.uid() AND warehouse_id IS NOT NULL
 AND public.has_show_access(show_id) AND public.has_warehouse_access(warehouse_id)
 AND original_show_id IS NOT DISTINCT FROM show_id
 AND (NOT is_marketing_asset OR public.has_permission('assets.marketing'))
 AND condition='unverified' AND location_type='warehouse' AND NOT is_archived
 AND EXISTS (SELECT 1 FROM public.profiles p JOIN public.roles r ON r.id=p.role_id WHERE p.id=auth.uid() AND p.is_active AND r.code IN ('executive_producer','creative_producer','warehouse_manager','line_producer'))
);
CREATE POLICY assets_update_metadata ON public.assets FOR UPDATE TO authenticated
 USING (public.has_permission('assets.edit') AND NOT is_archived AND public.has_show_access(show_id) AND public.has_warehouse_access(warehouse_id) AND (NOT is_marketing_asset OR public.has_permission('assets.marketing')))
 WITH CHECK (public.has_permission('assets.edit') AND NOT is_archived AND public.has_show_access(show_id) AND public.has_warehouse_access(warehouse_id) AND (NOT is_marketing_asset OR public.has_permission('assets.marketing')));
ALTER TABLE public.assets ADD CONSTRAINT assets_nonblank_name_number CHECK (btrim(name)<>'' AND btrim(inventory_number)<>'');
ALTER TABLE public.assets ADD CONSTRAINT assets_dimensions_nonnegative CHECK (width_cm>=0 AND height_cm>=0 AND depth_cm>=0 AND weight_kg>=0);
CREATE FUNCTION stage_private.asset_prepare_write() RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
BEGIN
 NEW.updated_at:=now();
 IF TG_OP='INSERT' AND NEW.condition='unverified' AND NEW.inspection_due_at IS NULL THEN
 NEW.inspection_due_at:=now()+interval '7 days';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER assets_prepare_write BEFORE INSERT OR UPDATE ON public.assets FOR EACH ROW EXECUTE FUNCTION stage_private.asset_prepare_write();
CREATE FUNCTION stage_private.asset_record_write() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor uuid:=auth.uid(); actor_name text; actor_role text;
BEGIN
 IF actor IS NOT NULL THEN
 SELECT p.full_name,r.code INTO actor_name,actor_role FROM public.profiles p JOIN public.roles r ON r.id=p.role_id WHERE p.id=actor AND p.is_active;
 IF NOT FOUND THEN RAISE EXCEPTION 'Inactive or missing profile'; END IF;
 END IF;
 IF TG_OP='INSERT' AND NEW.condition='unverified' THEN
 INSERT INTO public.inspections(asset_id,inspection_type,assigned_to,received_at,deadline_at)
 VALUES(NEW.id,'initial',NEW.responsible_id,now(),NEW.inspection_due_at);
 END IF;
 INSERT INTO public.audit_log(actor_id,actor_name,actor_role,action_type,entity_type,entity_id,asset_id,show_id,warehouse_id,description,old_values,new_values)
 VALUES(actor,actor_name,actor_role,lower(TG_OP),'asset',NEW.id,NEW.id,NEW.show_id,NEW.warehouse_id,CASE WHEN TG_OP='INSERT' THEN 'Створення картки' ELSE 'Зміна картки' END,CASE WHEN TG_OP='UPDATE' THEN to_jsonb(OLD) ELSE NULL END,to_jsonb(NEW));
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION stage_private.asset_record_write() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION stage_private.asset_prepare_write() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER assets_record_write AFTER INSERT OR UPDATE ON public.assets FOR EACH ROW EXECUTE FUNCTION stage_private.asset_record_write();
