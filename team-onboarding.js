'use strict';

async function renderTeamOnboarding() {
  const data = await take(db.rpc('stage_v1_invitation_options'));
  if (page !== 'team-onboarding') return;
  app.innerHTML = '<button type="button" class="back" id="team-onboard-back">‹ Профіль</button><h1>Запрошення працівників</h1>';
  app.querySelector('#team-onboard-back').onclick = () => go('profile');
  const add = document.createElement('button');
  add.className = 'primary full';
  add.textContent = 'Запросити працівника';
  add.onclick = () => onboardingForm(data);
  app.append(add);
  const labels = { pending:'Очікує прийняття',accepted:'Прийнято',expired:'Прострочено',cancelled:'Відкликано' };
  for (const invitation of data.invitations) {
    const card = document.createElement('section');
    card.className = 'card line';
    const state = invitation.status === 'pending' && Date.parse(invitation.expires_at) <= Date.now() ? 'expired' : invitation.status;
    card.textContent = invitation.email + ' · ' + (labels[state] || state);
    if (state === 'pending') {
      const button = document.createElement('button');
      button.className = 'full';
      button.textContent = 'Відкликати';
      button.onclick = () => form('Відкликати запрошення', '<p>' + esc(invitation.email) + '</p>', async () => {
        try { await take(db.rpc('stage_v1_cancel_invitation',{p_id:invitation.id})); return true; }
        catch (error) { fail(error); return false; }
      });
      card.append(button);
    }
    app.append(card);
  }
}

function onboardingForm(data) {
  const choices = (name, rows, key) => rows.map(row => '<label><input type="checkbox" style="width:auto" name="' +
    name + '" value="' + esc(row[key]) + '"> ' + esc(row.name) + '</label>').join('');
  form('Запросити працівника', '<label>Ім’я та прізвище<input name="name" autocomplete="name" maxlength="120" required></label>' +
    '<label>Електронна пошта<input name="email" type="email" autocomplete="email" required></label>' +
    '<label>Телефон<input name="phone" type="tel" autocomplete="tel" maxlength="40"></label>' +
    '<label>Посада<input name="job" maxlength="120"></label>' +
    '<h3>Проєкти</h3><label><input type="checkbox" style="width:auto" name="all_shows"> Усі доступні проєкти</label>' +
    choices('shows',data.shows,'id') + '<h3>Дозволи</h3>' + choices('actions',data.permissions,'code') +
    '<details><summary>Доступ до складів</summary><label><input type="checkbox" style="width:auto" name="all_warehouses"> Усі доступні склади</label>' +
    choices('warehouses',data.warehouses,'id') + '</details><p id="onboarding-error" role="alert"></p>',
    async values => {
      try {
        const result = await take(db.functions.invoke('stage-v1-invite',{body:{
          name:values.get('name'),email:values.get('email'),job:values.get('job'),phone:values.get('phone'),
          actions:values.getAll('actions'),shows:values.has('all_shows') ? null : values.getAll('shows'),
          warehouses:values.has('all_warehouses') ? null : values.getAll('warehouses')
        }}));
        toast(result.message);
        return true;
      } catch(error) {
        const response = await error.context?.json?.().catch(() => null);
        modal.querySelector('#onboarding-error').textContent = response?.message || error.message;
        return false;
      }
    });
  modal.querySelector('button[type=submit]').textContent = 'Надіслати запрошення';
}
