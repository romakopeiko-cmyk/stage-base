import assert from 'node:assert/strict';
import {createHmac, randomUUID} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {execFileSync} from 'node:child_process';

// This runner uses a freshly replayed disposable staging database and an
// isolated PostgREST container sharing its loopback network.
const container = 'stage-canonical-rehearsal';
const realAuth = process.env.STAGE_TEST_REAL_AUTH === '1';
const database = realAuth ? 'stage_security_auth' : 'stage_security_replay';
const keyFile = process.env.STAGE_TEST_JWT_FILE;
assert(realAuth || keyFile, 'Supply a disposable PostgREST signing key or use the local Auth service');
const key = realAuth ? null : readFileSync(keyFile,'utf8').trim();
const reader = '00000000-0000-4000-8000-000000000101';
const director = '00000000-0000-4000-8000-000000000102';
const unregistered = '00000000-0000-4000-8000-000000000103';
const asset = '00000000-0000-4000-8000-000000000121';
const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
function jwt(sub) {
  const input = encode({alg:'HS256',typ:'JWT'})+'.'+encode({role:'authenticated',sub,exp:Math.floor(Date.now()/1000)+600});
  return input+'.'+createHmac('sha256',key).update(input).digest('base64url');
}
function sql(input) {
  return execFileSync('docker',['exec','-i',container,'psql','-XAtq','-U','postgres','-d',database,'-v','ON_ERROR_STOP=1'],{input,encoding:'utf8'}).trim();
}
function http(port, route, token, body) {
  const headers = token ? 'Authorization: Bearer '+token+'\r\n' : '';
  const payload=body ? JSON.stringify(body) : '';
  const content=body ? 'Content-Type: application/json\r\nContent-Length: '+Buffer.byteLength(payload)+'\r\n' : '';
  const input=(body ? 'POST ' : 'GET ')+route+' HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n'+headers+content+'\r\n'+payload;
  const output = execFileSync('docker',['exec','-i',container,'bash','-c','exec 3<>/dev/tcp/127.0.0.1/$1; cat >&3; cat <&3','http',String(port)],{input,encoding:'utf8',timeout:5000});
  const [head,responseBody] = output.split('\r\n\r\n');
  return {status:Number(head.split(' ')[1]),body:JSON.parse(responseBody)};
}
const get=(route,token)=>http(realAuth ? 3001 : 3000,route,token);
function signIn() {
  const credentials={email:'fixture-'+randomUUID()+'@example.invalid',password:randomUUID()+randomUUID()};
  const signup=http(9999,'/signup',undefined,credentials);
  assert.equal(signup.status,200,'Local Auth signup');
  const login=http(9999,'/token?grant_type=password',undefined,credentials);
  assert.equal(login.status,200,'Local Auth password login');
  assert.match(login.body.user.id,/^[0-9a-f-]{36}$/);
  return {id:login.body.user.id,token:login.body.access_token};
}
function expectRows(route,token,n) {
  const result=get(route,token);
  assert.equal(result.status,200,route);
  assert.equal(result.body.length,n,route);
}
let fixture=readFileSync(new URL('./staging-postgres-matrix.sql',import.meta.url),'utf8')
  .split('set local role authenticated;')[0];
let readerId=reader;
let readerJwt, directorJwt, unregisteredJwt;
if (realAuth) {
  const users=[signIn(),signIn(),signIn()];
  [readerId,readerJwt,directorJwt,unregisteredJwt]=[users[0].id,users[0].token,users[1].token,users[2].token];
  fixture=fixture.replace(/insert into auth[.]users[\s\S]*?;\n/i,'');
  for(const [index,id] of [reader,director,unregistered].entries()) fixture=fixture.replaceAll(id,users[index].id);
} else {
  [readerJwt,directorJwt,unregisteredJwt]=[jwt(reader),jwt(director),jwt(unregistered)];
}
sql(fixture+'\ncommit;');
const access='/assets?select=id&inventory_number=like.FIXTURE-*';
const finance='/asset_finance?select=asset_id&asset_id=eq.'+asset;
const tasks='/stage_tasks?select=id&title=eq.Fixture%20task';

const anonymous=get(access);
assert([200,401,403].includes(anonymous.status));
if(anonymous.status===200) assert.deepEqual(anonymous.body,[]);
expectRows(access,unregisteredJwt,0);
expectRows(access,readerJwt,1);
expectRows(tasks,readerJwt,1);
expectRows(finance,readerJwt,0);
expectRows(finance,directorJwt,1);
sql("update public.profiles set is_active=false where id='"+readerId+"'");
expectRows(access,readerJwt,0);
expectRows(tasks,readerJwt,0);
expectRows(finance,readerJwt,0);
console.log('PASS PostgREST scope, finance and deactivation with an unchanged '+(realAuth?'GoTrue':'local fixture')+' JWT');
