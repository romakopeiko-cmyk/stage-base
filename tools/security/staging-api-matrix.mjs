import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {spawnSync} from 'node:child_process';

const base = new URL(process.env.STAGE_TEST_API ?? 'http://127.0.0.1:54321');
assert.equal(base.origin, 'http://127.0.0.1:54321', 'Only the isolated Supabase API is accepted');
const key = process.env.ANON_KEY ?? process.env.PUBLISHABLE_KEY;
const service = process.env.SERVICE_ROLE_KEY ?? process.env.SECRET_KEY;
assert(key && service, 'Use local Supabase status to supply API keys');

async function request(route, {method='GET', body, token, admin=false, contentType}={}) {
  const apiKey = admin ? service : key;
  const headers = {apikey:apiKey};
  const bearer = token ?? (apiKey.startsWith('eyJ') ? apiKey : undefined);
  if (bearer) headers.Authorization = `Bearer ${bearer}`;
  if (body !== undefined) headers['Content-Type'] = contentType ?? (typeof body === 'string' ? 'text/plain' : 'application/json');
  return fetch(new URL(route,base), {method,headers,body:typeof body === 'string' ? body : JSON.stringify(body)});
}
function sql(query) {
  const r=spawnSync('docker',['exec','-i','supabase_db_stage-security-local','psql','-XAtq','-U','postgres','-v','ON_ERROR_STOP=1'],{input:query,encoding:'utf8'});
  if(r.status!==0) throw Error(r.stderr);
  return r.stdout.trim();
}
async function user() {
  const email=`fixture-${randomUUID()}@example.invalid`;
  const password=randomUUID()+randomUUID();
  const created=await request('/auth/v1/admin/users',{method:'POST',admin:true,body:{email,password,email_confirm:true}});
  assert(created.ok, 'Synthetic user creation');
  const {id}=await created.json();
  assert.match(id,/^[0-9a-f-]{36}$/);
  const login=await request('/auth/v1/token?grant_type=password',{method:'POST',body:{email,password}});
  assert(login.ok, 'Synthetic password login');
  const {access_token:token}=await login.json();
  assert(token);
  return {id,token};
}
async function visible(table, token, filter, count) {
  const r=await request(`/rest/v1/${table}?select=*${filter}`,{token});
  if(count===0 && [401,403].includes(r.status)) return;
  assert(r.ok,`${table} unexpected HTTP ${r.status}`);
  assert.equal((await r.json()).length,count,table);
}
async function denied(route, options) {
  const r=await request(route,options);
  assert(!r.ok,`${route} expected permission denial`);
}
const reader=await user();
const noProfile=await user();
const director=await user();
const show=randomUUID();
const otherShow=randomUUID();
const first=randomUUID();
const second=randomUUID();
sql(`
insert into public.shows(id,name) values ('${show}','Fixture ${show}'),('${otherShow}','Fixture ${otherShow}');
insert into public.profiles(id,display_name,full_name,role_id,is_active,is_admin)
select '${reader.id}','Reader','Reader',id,true,false from public.roles where code='employee';
insert into public.profiles(id,display_name,full_name,role_id,is_active,is_admin)
select '${director.id}','Director','Director',id,true,false from public.roles where code='director';
insert into public.user_show_access(user_id,show_id) values('${reader.id}','${show}');
insert into public.stage_member_limits(user_id,show_ids,tasks_read,tasks_create,tasks_write,assets_read)
values ('${reader.id}',array['${show}'::uuid],true,false,false,true);
insert into public.assets(id,inventory_number,name,assigned_show_id)
values ('${first}','FIX-${first}','Fixture visible','${show}'),('${second}','FIX-${second}','Fixture hidden','${otherShow}');
insert into public.asset_finance(asset_id,replacement_value) values ('${first}',100);
`);
const task=sql(`insert into public.stage_tasks(owner_id,assigned_by,show_id,title,status)
values ('${reader.id}','${director.id}','${show}','Fixture task','doing') returning id;`);
assert.match(task,/^[0-9]+$/);
for(const token of [undefined,noProfile.token]){
  await visible('assets',token,`&id=eq.${first}`,0);
  await visible('stage_tasks',token,`&id=eq.${task}`,0);
  await visible('asset_finance',token,`&asset_id=eq.${first}`,0);
}
await visible('assets',reader.token,`&id=eq.${first}`,1);
await visible('assets',reader.token,`&id=eq.${second}`,0);
await visible('stage_tasks',reader.token,`&id=eq.${task}`,1);
await visible('asset_finance',reader.token,`&asset_id=eq.${first}`,0);
await visible('asset_finance',director.token,`&asset_id=eq.${first}`,1);
await denied('/rest/v1/stage_task_comments',{method:'POST',token:reader.token,body:{task_id:Number(task),author_id:reader.id,body:'Fixture comment'}});
const attachment=`/storage/v1/object/stage-task-files/${task}/${reader.id}/fixture.txt`;
await denied(attachment,{method:'POST',token:reader.token,body:'fixture'});
sql(`update public.stage_member_limits set tasks_write=true where user_id='${reader.id}';`);
assert((await request('/rest/v1/stage_task_comments',{method:'POST',token:reader.token,body:{task_id:Number(task),author_id:reader.id,body:'Allowed fixture'}})).ok,'Task writer comment');
assert((await request(attachment,{method:'POST',token:reader.token,body:'fixture'})).ok,'Task writer attachment');
for(const [bucket, extension, contentType] of [['stage-catalog-photos','png','image/png'],['stage-catalog-documents','txt','text/plain']]){
  const paths=[first,second].map(asset=>`/storage/v1/object/${bucket}/${asset}/${reader.id}/${randomUUID()}-fixture.${extension}`);
  for(const path of paths) {
    const r=await request(path,{method:'POST',admin:true,contentType,body:'synthetic fixture'});
    assert(r.ok,`fixture upload ${bucket}: ${r.status}`);
  }
  const authPath=path=>path.replace('/object/','/object/authenticated/');
  assert((await request(authPath(paths[0]),{token:reader.token})).ok,`scoped read ${bucket}`);
  await denied(authPath(paths[1]),{token:reader.token});
  await denied(authPath(paths[0]),{token:noProfile.token});
}
sql(`update public.profiles set is_active=false where id='${reader.id}';`);
await visible('assets',reader.token,`&id=eq.${first}`,0);
await visible('stage_tasks',reader.token,`&id=eq.${task}`,0);
await denied('/rest/v1/stage_task_comments',{method:'POST',token:reader.token,body:{task_id:Number(task),author_id:reader.id,body:'Inactive fixture'}});
await denied(attachment.replace('fixture.txt','inactive.txt'),{method:'POST',token:reader.token,body:'fixture'});
console.log('PASS local Auth, REST, Storage, project scope, task write, finance and unchanged-token deactivation');
