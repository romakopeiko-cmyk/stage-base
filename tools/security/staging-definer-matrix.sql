-- Disposable Staging replay only. Verify denial with no staff profile and after deactivation.
begin;
insert into auth.users(id,email) values
 ('00000000-0000-4000-8000-000000000201','unregistered@example.invalid'),
 ('00000000-0000-4000-8000-000000000202','disabled@example.invalid');
insert into public.profiles(id,display_name,role_id,is_active,is_admin)
select '00000000-0000-4000-8000-000000000202','Disabled administrator',id,false,true
from public.roles where code='creative_producer';
insert into public.stage_member_limits(user_id,assets_read)
values ('00000000-0000-4000-8000-000000000202',true);

set local role authenticated;
do $suite$
declare
  actor uuid;
  target constant uuid := '00000000-0000-4000-8000-000000000202';
  statement text;
begin
  foreach actor in array array[
    '00000000-0000-4000-8000-000000000201'::uuid,
    '00000000-0000-4000-8000-000000000202'::uuid
  ] loop
    perform set_config('request.jwt.claim.sub',actor::text,true);

    if public.can_read_asset(null,null) is distinct from false
       or public.has_permission('team.manage') is distinct from false
       or public.has_show_access(target) is distinct from false
       or public.stage_has_individual_access() is distinct from false
       or public.stage_member_active() is distinct from false
       or public.stage_within_limits('tasks.write',null,null) is distinct from false
       or public.stage_claim_team_invitation() is distinct from false
       or public.stage_catalog_capabilities() <> '{"create":false,"edit":false}'::jsonb
       or public.stage_catalog_media_capabilities() <> '{"photos":false,"documents":false}'::jsonb
       or public.stage_team_capabilities() <> '{"manage":false,"delegate":false}'::jsonb
       or exists(select 1 from stage_operations.team_task_people(target)) then
      raise exception 'Unexpected capability for a user without an active profile';
    end if;

    foreach statement in array array[
      'select public.stage_catalog_permissions_for($1,false,false)',
      'select public.stage_catalog_save(null,''Fixture'',null,null,null,null,null,null,''individual'',1,''шт.'')',
      'select public.stage_decide_team_task(1,true,null)',
      'select public.stage_invite_configuration()',
      'select public.stage_prepare_catalog_invitation(''audit@example.invalid'',''Fixture'',null,null,''{}'',false,''{"can_create":false,"can_edit":false,"can_photo":false,"can_document":false}'')',
      'select public.stage_prepare_contact_invitation(''audit@example.invalid'',''Fixture'',null,null,''{}'',false)',
      'select public.stage_prepare_individual_invitation(''audit@example.invalid'',''Fixture'',null,''{}'',false)',
      'select public.stage_save_member_catalog_permissions($1,null,false,false,false,false)',
      'select public.stage_team_directory()',
      'select public.stage_team_edit($1,''Fixture'',null,$1,true,false)',
      'select public.stage_team_invitation_action(''revoke'',$1,null,null,null)',
      'select public.stage_team_invitations()',
      'select public.stage_team_limits($1,null)',
      'select public.stage_team_transfer_tasks($1,$2)',
      'select stage_operations.team_task_assign($1,$2,''Fixture'',null,''medium'',null,null)'
    ] loop
      begin
        execute statement using target, actor;
        raise exception 'Operation succeeded without active profile: %',statement;
      exception when insufficient_privilege then null;
      end;
    end loop;
  end loop;
end;
$suite$;
rollback;
