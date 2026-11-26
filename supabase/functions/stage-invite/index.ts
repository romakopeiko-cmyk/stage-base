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
    const { action, id, email, name, job, access } = await request.json();
    if (!['invite', 'resend', 'revoke'].includes(action)) return respond('Невідома дія', 400);
    const prepare = action === 'invite';
    const change = await fetch(url + '/rest/v1/rpc/' + (prepare ? 'stage_prepare_individual_invitation' : 'stage_team_invitation_action'), {
      method: 'POST', headers: userHeaders,
      body: JSON.stringify(prepare ? { p_email: email, p_name: name, p_job: job ?? null, p_access: access }
        : { p_action: action, p_id: id ?? null, p_email: null, p_name: null, p_role: null })
    });
    if (!change.ok) {
      const error = await change.json().catch(() => ({}));
      const messages: Record<string, string> = {
        '42501': 'У вашого профілю немає права керувати запрошеннями.',
        '23505': 'Для цієї адреси вже є працівник або активне запрошення.',
        '22P02': 'Оберіть доступні шоу та склади.',
        '22023': action === 'resend' ? 'Запрошення закрито або ще не минула хвилина після спроби надсилання.'
          : 'Перевірте ім’я, email, дозволи та стан запрошення.'
      };
      return respond(messages[error.code] || 'Сервер відхилив запрошення.', error.code === '42501' ? 403 : 400);
    }
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
    if (sent.ok) return respond('Запрошення надіслано. Працівник отримає лист із посиланням для входу.', 200);
    const authError = await sent.json().catch(() => ({}));
    const code = authError.error_code ?? authError.code;
    const reason = code === 'over_email_send_rate_limit' || sent.status === 429 ? 'Вичерпано ліміт пошти Supabase. Спробуйте пізніше.'
      : code === 'email_address_not_authorized' ? 'Вбудована пошта Supabase не може надіслати лист на цю адресу. Перевірте SMTP.'
      : code === 'email_exists' ? 'Ця адреса вже зареєстрована в Supabase Auth. Скористайтеся повторним надсиланням.'
      : 'Поштова служба відхилила запит. Перевірте SMTP та журнал Auth.';
    return respond('Запрошення збережено. ' + reason, 502);
  } catch {
    return respond('Не вдалося обробити запрошення', 500);
  }
});
