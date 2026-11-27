Deno.serve(async request => {
  const origin = request.headers.get('Origin') ?? '';
  const local = /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(origin);
  const staging = origin === 'https://romakopeiko-cmyk.github.io';
  const allowedOrigin = local || staging;
  const headers = {
    'Access-Control-Allow-Origin': allowedOrigin ? origin : 'null',
    'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Cache-Control': 'no-store',
    'Content-Type': 'application/json'
  };
  const respond = (status: number, message: string) => new Response(JSON.stringify({ message }), { status,headers });
  if (!allowedOrigin) return respond(403,'Адреса тестового застосунку недоступна.');
  if (request.method === 'OPTIONS') return new Response(null,{status:204,headers});
  if (request.method !== 'POST') return respond(405,'Метод недоступний.');
  const authorization = request.headers.get('Authorization');
  if (!authorization?.startsWith('Bearer ')) return respond(401,'Потрібно увійти.');
  const base = Deno.env.get('SUPABASE_URL');
  const anon = Deno.env.get('SUPABASE_ANON_KEY');
  const privileged = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!base || !anon || !privileged) return respond(503,'Авторизацію не налаштовано.');
  const backend = new URL(base);
  const compatibleBackend = staging
    ? backend.origin === 'https://cnkwvrxlvvtmfiubtyks.supabase.co'
    : backend.protocol === 'http:' && (['127.0.0.1','localhost','kong'].includes(backend.hostname) || backend.hostname.startsWith('supabase_kong_'));
  if (!compatibleBackend) return respond(403,'Сервер не є погодженим тестовим середовищем.');
  try {
    const {email,name,phone,job,actions,shows,warehouses} = await request.json();
    const userHeaders = {Authorization:authorization,apikey:anon,'Content-Type':'application/json'};
    const auth = await fetch(base+'/auth/v1/user',{headers:userHeaders});
    if (!auth.ok) return respond(401,'Сесія недійсна.');
    const created = await fetch(base+'/rest/v1/rpc/stage_v1_prepare_invitation',{
      method:'POST',headers:userHeaders,body:JSON.stringify({
        p_email:email,p_name:name,p_phone:phone ?? null,p_job:job ?? null,
        p_actions:actions,p_shows:shows ?? null,p_warehouses:warehouses ?? null
      })
    });
    if (!created.ok) {
      const error = await created.json().catch(() => ({}));
      return error.code === '23505' ? respond(409,'Для цієї адреси вже є профіль або активне запрошення.')
        : respond(created.status === 403 ? 403 : 400,'Не вдалося підготувати запрошення. Перевірте права й дані.');
    }
    const redirect = encodeURIComponent(origin + (staging ? '/stage-base/staging/' : '/'));
    const sent = await fetch(base+'/auth/v1/invite?redirect_to='+redirect,{
      method:'POST',headers:{Authorization:'Bearer '+privileged,apikey:privileged,'Content-Type':'application/json'},
      body:JSON.stringify({email:email.trim().toLowerCase()})
    });
    return sent.ok ? respond(200,'Запрошення новому працівнику надіслано.')
      : respond(502,'Запрошення збережено. Поштова служба не прийняла запит.');
  } catch { return respond(500,'Не вдалося обробити запрошення.'); }
});
