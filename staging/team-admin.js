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
    const roleNames = new Map(roles.map(role => [role.id, role.name]));
    content.innerHTML = '<div id="team-members" class="card"></div><details class="card"><summary>Журнал адміністративних дій</summary><div id="team-audit"></div></details>';
    for (const member of members) {
      const row = document.createElement('div');
      row.className = 'line';
      row.innerHTML = '<b>' + esc(member.full_name) + '</b><p>' + esc(member.job_title || roleNames.get(member.role_id)) + '</p><small>' +
        (member.is_active ? 'Активний профіль' : 'Деактивовано') + (member.is_admin ? ' · Адміністратор' : '') + '</small>';
      const edit = document.createElement('button');
      edit.type = 'button';
      edit.className = 'full';
      edit.textContent = 'Редагувати';
      edit.onclick = () => editTeamMember(member, roles, rights);
      row.append(edit);
      if (rights.delegate && member.id !== me.id && roles.find(role => role.id === member.role_id)?.code !== 'executive_producer') {
        const access = document.createElement('button');
        access.className = 'full';
        access.textContent = 'Обмеження доступу';
        access.onclick = () => editStageLimits(member, rights).catch(fail);
        row.append(access);
      }
      content.querySelector('#team-members').append(row);
    }
    if (rights.delegate) renderTeamActions(content, roles, members, invitations, rights);
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

function editTeamMember(member, roles, rights) {
  const currentRole = roles.find(role => role.id === member.role_id);
  const accessEditable = rights.delegate && member.id !== me.id && currentRole?.code !== 'executive_producer';
  const options = roles.filter(role => role.id === member.role_id || role.code !== 'executive_producer').map(role =>
    '<option value="' + esc(role.id) + '"' + (role.id === member.role_id ? ' selected' : '') + '>' + esc(role.name) + '</option>').join('');
  form('Профіль працівника', `
    <label>Ім’я<input name="name" value="${esc(member.full_name)}" required maxlength="120"></label>
    <label>Посада<input name="job" value="${esc(member.job_title)}" maxlength="120"></label>
    <label>Системна роль<select name="role" ${accessEditable ? '' : 'disabled'}>${options}</select></label>
    ${accessEditable ? `<label><input type="checkbox" name="active" ${member.is_active ? 'checked' : ''}> Активний профіль</label>
      <label><input type="checkbox" name="admin" ${member.is_admin ? 'checked' : ''}> Адміністративні повноваження</label>` : ''}`,
    async data => {
      try {
        await take(db.rpc('stage_team_edit', {
          p_user: member.id, p_name: data.get('name'), p_job: data.get('job'),
          p_role: accessEditable ? data.get('role') : member.role_id,
          p_active: accessEditable ? data.has('active') : member.is_active,
          p_admin: accessEditable ? data.has('admin') : member.is_admin
        }));
        toast('Профіль оновлено');
        modal.close();
        await renderTeamAdmin(rights);
        return false;
      } catch (error) { fail(error); return false; }
    });
}

function renderTeamActions(content, roles, members, invitations, rights) {
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
  actions.querySelector('#invite').onclick = () => {
    const options = roles.filter(role => !['executive_producer','creative_producer'].includes(role.code))
      .map(role => '<option value="' + esc(role.id) + '">' + esc(role.name) + '</option>').join('');
    form('Запросити працівника', '<label>Ім’я<input name="name" maxlength="120" required></label>' +
      '<label>Email<input name="email" type="email" required></label><label>Системна роль<select name="role">' + options + '</select></label>',
      data => request({ action: 'invite', ...Object.fromEntries(data) }));
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
    row.textContent = invitation.email + ' · ' + (statuses[invitation.status] || invitation.status);
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

async function editStageLimits(member, rights) {
  const { limits, shows, warehouses } = await take(db.rpc('stage_team_limits', { p_user: member.id }));
  const checks = (name, rows, selected) => rows.map(row =>
    '<label><input type="checkbox" name="' + name + '" value="' + esc(row.id) + '"' +
    (selected?.includes(row.id) ? ' checked' : '') + '> ' + esc(row.name) + '</label>').join('');
  const scope = (name, label, items, selected) => '<fieldset><legend>' + label + '</legend><label><input type="checkbox" name="' +
    name + '_limited"' + (selected ? ' checked' : '') + '> Лише вибрані</label>' + checks(name, items, selected) + '</fieldset>';
  const feature = (name, label) => '<label><input type="checkbox" name="' + name + '"' +
    (limits?.[name] === false ? '' : ' checked') + '> ' + label + '</label>';
  form('Обмеження · ' + member.full_name,
    feature('tasks_read', 'Перегляд завдань') + feature('tasks_write', 'Створення і зміна завдань') +
    feature('assets_read', 'Перегляд майна') +
    scope('show_ids', 'Шоу', shows, limits?.show_ids) + scope('warehouse_ids', 'Склади', warehouses, limits?.warehouse_ids),
    async data => {
      await take(db.rpc('stage_team_limits', { p_user: member.id, p_limits: {
        tasks_read: data.has('tasks_read'), tasks_write: data.has('tasks_write'), assets_read: data.has('assets_read'),
        show_ids: data.has('show_ids_limited') ? data.getAll('show_ids') : null,
        warehouse_ids: data.has('warehouse_ids_limited') ? data.getAll('warehouse_ids') : null
      } }));
      toast('Обмеження збережено');
      modal.close();
      await renderTeamAdmin(rights);
      return false;
    });
}
