const origin = 'https://romakopeiko-cmyk.github.io';
const headers = {
  'Access-Control-Allow-Origin': origin,
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Content-Type': 'application/json',
  'Cache-Control': 'no-store'
};
const respond = (message: string, status: number) =>
  new Response(JSON.stringify({ message }), { status, headers });

Deno.serve(async request => {
  if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers });
  if (request.method !== 'POST') return respond('Метод недоступний', 405);

  const token = request.headers.get('Authorization');
  if (!token?.startsWith('Bearer ')) return respond('Потрібно увійти', 401);
  const url = Deno.env.get('SUPABASE_URL');
  const anon = Deno.env.get('SUPABASE_ANON_KEY');
  const privileged = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !anon || !privileged) return respond('Auth не налаштовано', 503);

  try {
    const userHeaders = { Authorization: token, apikey: anon, 'Content-Type': 'application/json' };
    const user = await fetch(url + '/auth/v1/user', { headers: userHeaders });
    if (!user.ok) return respond('Сесія недійсна', 401);
    const { action, id, email, name, role } = await request.json();
    if (!['invite', 'resend', 'revoke'].includes(action)) return respond('Невідома дія', 400);
    const change = await fetch(url + '/rest/v1/rpc/stage_team_invitation_action', {
      method: 'POST', headers: userHeaders,
      body: JSON.stringify({ p_action: action, p_id: id ?? null, p_email: email ?? null,
        p_name: name ?? null, p_role: role ?? null })
    });
    if (!change.ok) return respond('Дію відхилено. Перевірте права або стан запрошення.', change.status === 403 ? 403 : 400);
    const invitation = await change.json();
    if (action === 'revoke') return respond('Запрошення відкликано', 200);

    const redirect = encodeURIComponent(origin + '/stage-base/staging/');
    const authHeaders = { Authorization: 'Bearer ' + privileged, apikey: privileged, 'Content-Type': 'application/json' };
    let sent = await fetch(url + '/auth/v1/invite?redirect_to=' + redirect, {
      method: 'POST', headers: authHeaders, body: JSON.stringify({ email: invitation.email })
    });
    if (action === 'resend' && [400, 422].includes(sent.status)) {
      sent = await fetch(url + '/auth/v1/otp?redirect_to=' + redirect, {
        method: 'POST', headers: { apikey: anon, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email: invitation.email, create_user: false })
      });
    }
    return sent.ok ? respond('Supabase Auth прийняв запит на надсилання', 200)
      : respond('Запрошення збережено. Supabase Auth не прийняв запит на надсилання.', 502);
  } catch {
    return respond('Не вдалося обробити запрошення', 500);
  }
});
