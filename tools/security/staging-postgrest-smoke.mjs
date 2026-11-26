import assert from 'node:assert/strict';
import {createHmac} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {execFileSync} from 'node:child_process';

// This runner uses a freshly replayed disposable staging database and an
// isolated PostgREST container sharing its loopback network.
const container = 'stage-canonical-rehearsal';
const database = 'stage_security_replay';
const keyFile = process.env.STAGE_TEST_JWT_FILE;
assert(keyFile, 'Supply the path to the disposable PostgREST signing key');
const key = readFileSync(keyFile,'utf8').trim();
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
function get(route,token) {
  const headers = token ? 'Authorization: Bearer '+token+'\r\n' : '';
  const input = 'GET '+route+' HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n'+headers+'\r\n';
  const output = execFileSync('docker',['exec','-i',container,'bash','-c','exec 3<>/dev/tcp/127.0.0.1/3000; cat >&3; cat <&3'],{input,encoding:'utf8',timeout:5000});
  const [head,body] = output.split('\r\n\r\n');
  return {status:Number(head.split(' ')[1]),body:JSON.parse(body)};
}
function expectRows(route,token,n) {
  const result=get(route,token);
  assert.equal(result.status,200,route);
  assert.equal(result.body.length,n,route);
}
const fixture=readFileSync(new URL('./staging-postgres-matrix.sql',import.meta.url),'utf8')
  .split('set local role authenticated;')[0];
sql(fixture+'\ncommit;');
const access='/assets?select=id&inventory_number=like.FIXTURE-*';
const finance='/asset_finance?select=asset_id&asset_id=eq.'+asset;
const tasks='/stage_tasks?select=id&title=eq.Fixture%20task';
const readerJwt=jwt(reader);
assert([200,401,403].includes(get(access).status));
const anonymous=get(access);
if(anonymous.status===200) assert.deepEqual(anonymous.body,[]);
expectRows(access,jwt(unregistered),0);
expectRows(access,readerJwt,1);
expectRows(tasks,readerJwt,1);
expectRows(finance,readerJwt,0);
expectRows(finance,jwt(director),1);
sql("update public.profiles set is_active=false where id='"+reader+"'");
expectRows(access,readerJwt,0);
expectRows(tasks,readerJwt,0);
expectRows(finance,readerJwt,0);
console.log('PASS PostgREST scope, finance and deactivation using the same signed local JWT');
