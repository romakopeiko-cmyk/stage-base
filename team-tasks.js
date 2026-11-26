'use strict';

const canManageTeamTasks = () => ['executive_producer', 'creative_producer'].includes(roleCode());

function teamTaskForm() {
  const priorities = Object.entries(taskPriorities).map(([key, label]) =>
    `<option value="${key}" ${key === 'medium' ? 'selected' : ''}>${label}</option>`).join('');
  form('Призначити завдання', `
    <label>Шоу<select name="show" required>${optionIds('shows')}</select></label>
    <label>Виконавець<select name="person" required disabled><option value="">Спочатку оберіть шоу</option></select></label>
    <label>Назва<input name="title" maxlength="180" required></label>
    <label>Опис<textarea name="description" maxlength="8000"></textarea></label>
    <label>Пріоритет<select name="priority">${priorities}</select></label>
    ${field('start', 'Початок', 'datetime-local', false)}${field('due', 'Строк', 'datetime-local', false)}`,
  async data => {
    if (!data.get('person')) {
      toast('Оберіть відповідального виконавця');
      return false;
    }
    const iso = key => data.get(key) ? new Date(data.get(key)).toISOString() : null;
    try {
      await take(db.rpc('stage_team_task_assign', {
        p_show: data.get('show'), p_assignee: data.get('person'), p_title: data.get('title'),
        p_description: data.get('description'), p_priority: data.get('priority'),
        p_start: iso('start'), p_due: iso('due')
      }));
      toast('Завдання призначено');
      taskMode = 'created';
      return true;
    } catch (error) { fail(error); return false; }
  });
  const show = modal.querySelector('[name=show]');
  const person = modal.querySelector('[name=person]');
  let generation = 0;
  show.onchange = async () => {
    const current = ++generation;
    person.replaceChildren(new Option('Оберіть виконавця', ''));
    person.disabled = true;
    if (!show.value) return;
    try {
      const people = await take(db.rpc('stage_team_task_people', { p_show: show.value }));
      if (current !== generation || !person.isConnected) return;
      if (!people.length) {
        person.firstElementChild.textContent = 'Немає доступних співробітників';
        return;
      }
      for (const employee of people) person.add(new Option(employee.name, employee.id));
      person.disabled = false;
    } catch (error) {
      if (current === generation && person.isConnected) fail(error);
    }
  };
}

function openAssignedTask(task) {
  const assignedToMe = task.owner_id === me.id;
  const states = Object.entries(taskStatuses).map(([value, label]) =>
    `<option value="${value}" ${value === task.status ? 'selected' : ''}>${label}</option>`).join('');
  const details = `<h3>${esc(task.title)}</h3><p>${esc(task.description)}</p>
    <p>Шоу — ${esc(nameOf('shows', task.show_id))}</p>
    ${task.due_at ? `<p>Строк — ${esc(taskDate(task.due_at))}</p>` : ''}`;
  if (!assignedToMe) {
    modal.innerHTML = `<h2>${esc(taskNumber(task.id))}</h2>${details}
      <p>${esc(taskStatuses[task.status])}</p><button class="full" onclick="modal.close()">Закрити</button>`;
    modal.showModal();
    return;
  }
  form(taskNumber(task.id), details + `<label>Статус<select name="status">${states}</select></label>`, async data => {
    try {
      await saveTask(task, { status: data.get('status') });
      return true;
    } catch (error) { fail(error); return false; }
  });
}
