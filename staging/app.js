'use strict';

const db = supabase.createClient('https://cnkwvrxlvvtmfiubtyks.supabase.co', 'sb_publishable_tJdds19lGTk7W-Fj0PqXNQ_t0Q5tevw');
const app = document.querySelector('#app');
const modal = document.querySelector('#modal');
let me;
const esc = value => String(value ?? '').replace(/[&<>"']/g, char =>
  ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' })[char]);
const toast = message => { document.querySelector('#notice').textContent = message; };
const fail = error => toast(error.message || 'Сталася помилка');
async function take(request) {
  const { data, error } = await request;
  if (error) throw error;
  return data;
}

function form(title, body, submit) {
  modal.innerHTML = '<h2>' + esc(title) + '</h2><form>' + body +
    '<button class="primary full">Зберегти</button><button class="full" type="button">Скасувати</button></form>';
  modal.querySelector('[type=button]').onclick = () => modal.close();
  modal.querySelector('form').onsubmit = async event => {
    event.preventDefault();
    const button = event.submitter;
    button.disabled = true;
    try { if (await submit(new FormData(event.target))) modal.close(); }
    catch (error) { fail(error); }
    finally { button.disabled = false; }
  };
  modal.showModal();
}

function go() {
  app.innerHTML = '<h1>Профіль</h1><div class="card"><b>' + esc(me.full_name) +
    '</b><p>' + esc(me.job_title) + '</p><button class="full" id="profile-team" hidden>Команда</button>' +
    '<button class="full" id="password">Встановити або змінити пароль</button><button class="full" id="logout">Вийти</button></div>';
  app.querySelector('#logout').onclick = async () => { await db.auth.signOut(); login(); };
  app.querySelector('#password').onclick = () => form('Пароль', '<label>Новий пароль<input type="password" name="password" autocomplete="new-password" minlength="12" required></label>',
    async fields => { await take(db.auth.updateUser({ password: fields.get('password') })); toast('Пароль збережено'); return true; });
  renderProfileTeam();
}

function login() {
  me = null;
  app.innerHTML = '<h1>Вхід у Staging</h1><form class="card"><label>Email<input name="email" type="email" autocomplete="username" required></label>' +
    '<label>Пароль<input name="password" type="password" autocomplete="current-password" required></label>' +
    '<button class="primary full">Увійти</button></form>';
  app.querySelector('form').onsubmit = async event => {
    event.preventDefault();
    const data = new FormData(event.target);
    event.submitter.disabled = true;
    try {
      const { session } = await take(db.auth.signInWithPassword({ email: data.get('email'), password: data.get('password') }));
      await openSession(session);
    } catch (error) { fail(error); }
    finally { event.submitter.disabled = false; }
  };
}

async function openSession(session) {
  await take(db.rpc('stage_claim_team_invitation'));
  const active = await take(db.rpc('stage_member_active'));
  if (!active) {
    await db.auth.signOut({ scope: 'local' });
    login();
    toast('Активний профіль Staging відсутній. Зверніться до адміністратора.');
    return;
  }
  me = await take(db.from('profiles').select('id,full_name,job_title').eq('id', session.user.id).single());
  toast('');
  go();
}

document.addEventListener('DOMContentLoaded', async () => {
  try {
    const { session } = await take(db.auth.getSession());
    if (session) await openSession(session);
    else login();
  } catch (error) { login(); fail(error); }
});
