ALTER TABLE public.asset_photos ALTER COLUMN uploaded_by SET DEFAULT auth.uid();
ALTER TABLE public.asset_documents ALTER COLUMN uploaded_by SET DEFAULT auth.uid();
GRANT INSERT (asset_id,storage_path,comment) ON public.asset_photos TO authenticated;
GRANT INSERT (asset_id,name,storage_path,file_size,mime_type,comment) ON public.asset_documents TO authenticated;
CREATE POLICY asset_photos_insert ON public.asset_photos FOR INSERT TO authenticated WITH CHECK (
 uploaded_by=auth.uid() AND public.has_permission('assets.photos') AND split_part(storage_path,'/',1)=asset_id::text
 AND EXISTS(SELECT 1 FROM public.assets a WHERE a.id=asset_id)
);
CREATE POLICY asset_documents_insert ON public.asset_documents FOR INSERT TO authenticated WITH CHECK (
 uploaded_by=auth.uid() AND public.has_permission('assets.documents') AND split_part(storage_path,'/',1)=asset_id::text
 AND EXISTS(SELECT 1 FROM public.assets a WHERE a.id=asset_id)
);
