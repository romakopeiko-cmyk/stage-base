GRANT SELECT ON public.asset_components TO authenticated;
GRANT INSERT(asset_id,name,description,quantity,comment) ON public.asset_components TO authenticated;
CREATE POLICY components_read ON public.asset_components FOR SELECT TO authenticated USING (EXISTS(SELECT 1 FROM public.assets a WHERE a.id=asset_components.asset_id));
CREATE POLICY components_add ON public.asset_components FOR INSERT TO authenticated WITH CHECK (public.has_permission('assets.edit') AND EXISTS(SELECT 1 FROM public.assets a WHERE a.id=asset_components.asset_id AND a.tracking_type='set' AND NOT a.is_archived AND a.condition='unverified'));
GRANT SELECT(id,asset_id,status,inspection_type,deadline_at,condition_result,inspected_at,completeness_confirmed) ON public.inspections TO authenticated;
CREATE POLICY inspections_read ON public.inspections FOR SELECT TO authenticated USING (public.has_permission('inspections.view') AND EXISTS(SELECT 1 FROM public.assets a WHERE a.id=inspections.asset_id));
GRANT SELECT(id,asset_id,actor_name,actor_role,description,created_at) ON public.audit_log TO authenticated;
CREATE POLICY audit_asset_read ON public.audit_log FOR SELECT TO authenticated USING (public.has_permission('audit.view') AND NOT is_sensitive AND EXISTS(SELECT 1 FROM public.assets a WHERE a.id=audit_log.asset_id));
CREATE FUNCTION stage_private.complete_inspection(p_asset uuid,p_condition text,p_complete boolean,p_comment text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE a public.assets%ROWTYPE; i public.inspections%ROWTYPE; actor uuid:=auth.uid();
BEGIN
 IF actor IS NULL OR NOT public.has_permission('inspections.perform') OR NOT EXISTS(SELECT 1 FROM public.profiles p JOIN public.roles r ON r.id=p.role_id WHERE p.id=actor AND p.is_active AND r.code IN ('executive_producer','creative_producer','warehouse_manager','line_producer')) THEN RAISE EXCEPTION 'Недостатньо прав'; END IF;
 SELECT * INTO a FROM public.assets WHERE id=p_asset FOR UPDATE;
 IF NOT FOUND OR a.is_archived OR a.location_type<>'warehouse' OR NOT public.has_show_access(a.show_id) OR NOT public.has_warehouse_access(a.warehouse_id) OR (a.is_marketing_asset AND NOT public.has_permission('assets.marketing')) THEN RAISE EXCEPTION 'Майно недоступне'; END IF;
 SELECT * INTO i FROM public.inspections WHERE asset_id=p_asset AND status IN ('pending','in_progress') ORDER BY received_at DESC LIMIT 1 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Немає відкритої перевірки'; END IF;
 IF p_condition IS NULL OR p_condition NOT IN ('good','damaged','unusable') OR p_complete IS NULL THEN RAISE EXCEPTION 'Некоректний стан'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.asset_photos p JOIN storage.objects o ON o.bucket_id='asset-photos' AND o.name=p.storage_path WHERE p.asset_id=p_asset AND p.uploaded_by=actor AND p.created_at>=i.received_at AND o.created_at>=i.received_at) THEN RAISE EXCEPTION 'Спочатку завантажте актуальне фото'; END IF;
 IF a.tracking_type='set' THEN RAISE EXCEPTION 'Комплект потребує окремої перевірки складових'; END IF;
 UPDATE public.inspections SET status='completed',condition_result=p_condition,completeness_confirmed=p_complete,inspected_by=actor,inspected_at=now(),comment=p_comment,updated_at=now() WHERE id=i.id;
 UPDATE public.assets SET condition=CASE WHEN NOT p_complete AND p_condition='good' THEN 'damaged' ELSE p_condition END,completeness=CASE WHEN p_complete THEN 'Комплектний' ELSE 'Неповний' END,last_inspected_at=now(),inspection_due_at=NULL WHERE id=p_asset;
END $$;
REVOKE ALL ON FUNCTION stage_private.complete_inspection(uuid,text,boolean,text) FROM PUBLIC,anon,authenticated;
GRANT USAGE ON SCHEMA stage_private TO authenticated;
GRANT EXECUTE ON FUNCTION stage_private.complete_inspection(uuid,text,boolean,text) TO authenticated;
CREATE FUNCTION public.complete_inspection(p_asset uuid,p_condition text,p_complete boolean,p_comment text) RETURNS void LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT stage_private.complete_inspection(p_asset,p_condition,p_complete,p_comment) $$;
REVOKE ALL ON FUNCTION public.complete_inspection(uuid,text,boolean,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.complete_inspection(uuid,text,boolean,text) TO authenticated;
