-- Run after taking the candidate invitation endpoint out of service.
-- Canonical rows written before rollback retain valid legacy fields.
begin;
drop trigger stage_v1_fill_legacy_employee_profile on public.profiles;
drop function public.stage_v1_fill_legacy_employee_profile();
commit;
