'use strict';

async function renderProfileTeam() {
  const entry = app.querySelector('#profile-team');
  try {
    const rights = await take(db.rpc('stage_team_capabilities'));
    if (!entry?.isConnected || !rights.manage) return;
    entry.hidden = false;
    entry.onclick = () => renderTeamAdmin(rights);
  } catch {
    // The module is optional until its migration is installed.
  }
}

async function renderTeamAdmin(rights) {
  app.innerHTML = '<button id="team-back" class="back" type="button">‹ Профіль</button><h1>Команда</h1><div id="team-content" aria-live="polite">Завантаження…</div>';
  app.querySelector('#team-back').onclick = () => go('profile');
  const content = app.querySelector('#team-content');
  try {
    const [{ members, roles, audit }, invitations] = await Promise.all([
      take(db.rpc('stage_team_directory')), take(db.rpc('stage_team_invitations'))
    ]);
    if (!content.isConnected) return;
    const names = new Map(members.map(member => [member.id, member.full_name]));
    const duplicateNames = new Map();
    for (const member of members) {
      const key = member.full_name.trim().toLocaleLowerCase('uk');
      duplicateNames.set(key, (duplicateNames.get(key) || 0) + 1);
    }
    const manageable = members.filter(member => !member.is_admin && member.id !== me.id &&
      !['executive_producer','creative_producer'].includes(roles.find(role => role.id === member.role_id)?.code));
    content.innerHTML = '<div id="team-members" class="card"></div><details class="card"><summary>Журнал адміністративних дій</summary><div id="team-audit"></div></details>';
    for (const member of members) {
      const row = document.createElement('div');
      row.className = 'line';
      row.innerHTML = '<b>' + esc(member.full_name) + '</b><p>' + esc(member.job_title || 'Посаду не вказано') + '</p><small>' +
        (member.is_active ? 'Активний профіль' : 'Деактивовано') + (member.is_admin ? ' · Адміністратор' : '') + '</small>';
      if (duplicateNames.get(member.full_name.trim().toLocaleLowerCase('uk')) > 1) {
        const identifier = document.createElement('p');
        identifier.textContent = 'Профіль ' + member.id.slice(-8);
        row.append(identifier);
      }
      const edit = document.createElement('button');
      edit.type = 'button';
      edit.className = 'full';
      edit.textContent = 'Редагувати';
      edit.onclick = () => editTeamMember(member, rights, manageable.includes(member));
      row.append(edit);
      if (rights.delegate && manageable.includes(member)) {
        const access = document.createElement('button');
        access.className = 'full';
        access.textContent = 'Права доступу';
        access.onclick = () => editStageLimits(member, rights, manageable).catch(fail);
        row.append(access);
      }
      content.querySelector('#team-members').append(row);
    }
    if (rights.delegate) renderTeamActions(content, members, invitations, rights);
    const log = content.querySelector('#team-audit');
    if (!audit.length) log.textContent = 'Дій поки немає.';
    for (const event of audit) {
      const row = document.createElement('p');
      row.textContent = new Date(event.created_at).toLocaleString('uk-UA') + ' · ' + (names.get(event.actor) || 'Адміністратор') +
        ' · ' + ({
          'profile.updated': 'Оновлено профіль',
          'invitation.invite': 'Створено запрошення',
          'invitation.resend': 'Повторне надсилання',
          'invitation.revoke': 'Відкликано запрошення',
          'tasks.transferred': 'Передано завдань: ' + (event.changes?.count ?? 0)
        }[event.action] || 'Змінено права');
      log.append(row);
    }
  } catch (error) {
    if (content.isConnected) content.textContent = 'Команда недоступна.';
    fail(error);
  }
}

function editTeamMember(member, rights, manageable) {
  const canDeactivate = rights.delegate && manageable;
  form('Профіль працівника', `
    <label>Ім’я та прізвище<input name="name" value="${esc(member.full_name)}" required maxlength="120"></label>
    <label>Посада<input name="job" value="${esc(member.job_title)}" maxlength="120"></label>
    ${canDeactivate ? `<label><input type="checkbox" name="active" ${member.is_active ? 'checked' : ''}> Активний профіль</label>` : ''}`,
    async data => {
      await take(db.rpc('stage_team_edit', {
        p_user: member.id, p_name: data.get('name'), p_job: data.get('job'), p_role: member.role_id,
        p_active: canDeactivate ? data.has('active') : member.is_active, p_admin: member.is_admin
      }));
      toast('Профіль оновлено');
      modal.close();
      await renderTeamAdmin(rights);
      return false;
    });
}

function renderTeamActions(content, members, invitations, rights) {
  const actions = document.createElement('section');
  actions.className = 'card';
  actions.innerHTML = '<button class="primary full" id="invite">Запросити працівника</button>' +
    '<button class="full" id="transfer">Передати активні завдання</button>' +
    '<details><summary>Запрошення</summary><div id="invitations"></div></details>';
  content.prepend(actions);
  const request = async payload => {
    try {
      const result = await take(db.functions.invoke('stage-invite', { body: payload }));
      toast(result.message);
      if (modal.open) modal.close();
    } catch (error) {
      const body = await error.context?.json().catch(() => null);
      toast(body?.message || error.message);
    }
    await renderTeamAdmin(rights);
    return false;
  };
  actions.querySelector('#invite').onclick = async () => {
    try {
      const options = await take(db.rpc('stage_invite_configuration'));
      form('Запросити працівника', '<label>Ім’я та прізвище<input name="name" maxlength="120" required></label>' +
        '<label>Електронна пошта<input name="email" type="email" required></label>' +
        '<label>Посада<input name="job" maxlength="120"></label>' + accessFields(options),
        data => request({ action: 'invite', name: data.get('name'), email: data.get('email'),
          job: data.get('job'), access: accessFrom(data) }), 'Надіслати запрошення');
      bindAccessFields();
    } catch (error) { fail(error); }
  };
  actions.querySelector('#transfer').onclick = () => {
    const options = people => '<option value="">Оберіть працівника</option>' + people.map(person =>
      '<option value="' + esc(person.id) + '">' + esc(person.full_name) + '</option>').join('');
    form('Передати активні командні завдання', '<label>Від<select name="from" required>' + options(members) +
      '</select></label><label>Кому<select name="to" required>' + options(members.filter(person => person.is_active)) + '</select></label>',
      async data => {
        const count = await take(db.rpc('stage_team_transfer_tasks', { p_from: data.get('from'), p_to: data.get('to') }));
        toast('Передано завдань: ' + count);
        modal.close();
        await renderTeamAdmin(rights);
        return false;
      });
  };
  for (const invitation of invitations) {
    const row = document.createElement('div');
    row.className = 'line';
    const statuses = { pending: 'Очікує', revoked: 'Відкликано', accepted: 'Прийнято' };
    row.textContent = invitation.email + ' · ' + (invitation.status === 'pending' && Date.parse(invitation.expires_at) <= Date.now()
      ? 'Прострочено' : (statuses[invitation.status] || invitation.status));
    if (invitation.status === 'pending') {
      for (const [action, label] of [['resend','Надіслати повторно'],['revoke','Відкликати']]) {
        const button = document.createElement('button');
        button.className = 'full';
        button.textContent = label;
        button.onclick = async () => { button.disabled = true; await request({ action, id: invitation.id }); };
        row.append(button);
      }
    }
    actions.querySelector('#invitations').append(row);
  }
}

const stageAccessGroups = {
  'Завдання': { tasks_read: 'Перегляд власних завдань', tasks_create: 'Створення завдань', tasks_write: 'Редагування завдань' },
  'Каталог майна': { assets_read: 'Перегляд каталогу' },
  'Шоу': { shows_read: 'Перегляд шоу' },
  'Склади': { warehouses_read: 'Перегляд складів' }
};
const stageAccessKeys = Object.values(stageAccessGroups).flatMap(Object.keys);

function accessFields({ shows, warehouses }, values = {}) {
  const groups = Object.entries(stageAccessGroups).map(([title, fields]) => `
    <details class="permission-group"><summary>${esc(title)} <output></output></summary>
      <label><input type="checkbox" data-select-all> Вибрати всі</label>
      ${Object.entries(fields).map(([key, label]) =>
        `<label><input type="checkbox" name="${key}" data-permission ${values[key] ? 'checked' : ''}> ${esc(label)}</label>`).join('')}
    </details>`).join('');
  const scope = (name, label, rows) => `<fieldset><legend>${label}</legend>
    <label><select name="${name}_mode">
      <option value="specific">Лише вибрані</option><option value="all" ${values[name] === null ? 'selected' : ''}>Усі</option>
    </select></label>${rows.map(row =>
      `<label><input type="checkbox" name="${name}" value="${esc(row.id)}" ${values[name]?.includes(row.id) ? 'checked' : ''}> ${esc(row.name)}</label>`).join('')}
    </fieldset>`;
  return '<h3>Індивідуальні права</h3>' + groups +
    '<p><small>Перегляд завдань потрібен для їх створення та редагування. У формі доступні дозволи, які підтримує сервер Staging.</small></p>' +
    scope('show_ids', 'Шоу', shows) + scope('warehouse_ids', 'Склади', warehouses);
}

function accessFrom(data) {
  return {
    ...Object.fromEntries(stageAccessKeys.map(key => [key, data.has(key)])),
    show_ids: data.get('show_ids_mode') === 'all' ? null : data.getAll('show_ids'),
    warehouse_ids: data.get('warehouse_ids_mode') === 'all' ? null : data.getAll('warehouse_ids')
  };
}

function bindAccessFields() {
  for (const group of modal.querySelectorAll('.permission-group')) {
    const all = group.querySelector('[data-select-all]');
    const options = [...group.querySelectorAll('[data-permission]')];
    const refresh = () => {
      const count = options.filter(option => option.checked).length;
      group.querySelector('output').textContent = count + ' / ' + options.length;
      all.checked = count === options.length;
      all.indeterminate = count > 0 && count < options.length;
    };
    all.onchange = () => { options.forEach(option => { option.checked = all.checked; }); refresh(); };
    group.addEventListener('change', refresh);
    refresh();
  }
}

async function editStageLimits(member, rights, manageable) {
  const current = await take(db.rpc('stage_team_limits', { p_user: member.id }));
  const options = manageable.filter(person => person.id !== member.id);
  form('Права доступу · ' + member.full_name, `
    <label>Копіювати права працівника<select id="copy-permissions"><option value="">Оберіть працівника</option>
      ${options.map(person => `<option value="${esc(person.id)}">${esc(person.full_name)} · ${esc(person.id.slice(-8))}</option>`).join('')}
    </select></label>` + accessFields(current, current.limits || {}),
    async data => {
      await take(db.rpc('stage_team_limits', { p_user: member.id, p_limits: accessFrom(data) }));
      toast('Права доступу збережено');
      modal.close();
      await renderTeamAdmin(rights);
      return false;
    });
  bindAccessFields();
  modal.querySelector('#copy-permissions').onchange = async event => {
    const select = event.target;
    const source = select.value;
    if (!source) return;
    try {
      const { limits } = await take(db.rpc('stage_team_limits', { p_user: source }));
      if (!select.isConnected || select.value !== source) return;
      if (!limits) { toast('У працівника немає індивідуального набору прав.'); return; }
      for (const key of stageAccessKeys) {
        const control = modal.querySelector('[name="' + key + '"]');
        control.checked = limits[key] === true;
        control.dispatchEvent(new Event('change', { bubbles: true }));
      }
      for (const key of ['show_ids','warehouse_ids']) {
        modal.querySelector('[name="' + key + '_mode"]').value = limits[key] === null ? 'all' : 'specific';
        for (const control of modal.querySelectorAll('[name="' + key + '"]')) {
          control.checked = limits[key]?.includes(control.value) || false;
        }
      }
      toast('Набір скопійовано до форми. Збережіть, щоб застосувати права.');
    } catch (error) { fail(error); }
  };
}
