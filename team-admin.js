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
    const { members, roles, audit } = await take(db.rpc('stage_team_directory'));
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
      content.querySelector('#team-members').append(row);
    }
    const log = content.querySelector('#team-audit');
    if (!audit.length) log.textContent = 'Дій поки немає.';
    for (const event of audit) {
      const row = document.createElement('p');
      row.textContent = new Date(event.created_at).toLocaleString('uk-UA') + ' · ' + (names.get(event.actor) || 'Адміністратор') +
        ' оновив профіль «' + (names.get(event.subject) || 'Працівник') + '»';
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
