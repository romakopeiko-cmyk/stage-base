'use strict';

const taskStatuses = {
  planned: 'Заплановано', todo: 'До виконання', doing: 'В роботі',
  review: 'На перевірці', done: 'Виконано', blocked: 'Заблоковано'
};
const taskPriorities = { critical: 'Критичний', high: 'Високий', medium: 'Середній', low: 'Низький' };
const taskDate = value => value ? new Date(value).toLocaleString('uk-UA') : '';
const taskNumber = id => 'STG-' + String(id).padStart(4, '0');
let taskMode = 'active';

async function readTasks() {
  const items = [];
  for (let start = 0; ; start += 100) {
    const batch = await take(db.from('stage_tasks')
      .select('id,title,description,priority,status,starts_at,due_at,updated_at,inspection_id,inspection_asset_id')
      .order('due_at', { nullsFirst: false }).order('id').range(start, start + 99));
    items.push(...batch);
    if (batch.length < 100) return items;
  }
}

function taskOverdue(task) {
  return task.status !== 'done' && task.due_at && +new Date(task.due_at) < Date.now();
}

function taskCard(task, draggable = false) {
  const card = document.createElement('article');
  card.className = 'card line';
  card.dataset.priority = task.priority;
  card.innerHTML = `<small>${esc(taskNumber(task.id))}</small><h3>${esc(task.title)}</h3>
    <p>${esc(taskPriorities[task.priority])} · ${esc(taskStatuses[task.status])}</p>
    ${task.due_at ? `<p>Строк ${esc(taskDate(task.due_at))}</p>` : ''}
    ${taskOverdue(task) ? '<strong class="task-overdue">Прострочено</strong>' : ''}`;
  const button = document.createElement('button');
  button.className = 'full';
  button.textContent = 'Відкрити';
  button.onclick = () => {
    if (task.inspection_id) {
      liveDetail(task.inspection_asset_id);
      if (page === 'tasks' || page === 'home') toast('Картка майна недоступна');
      return;
    }
    taskForm(task);
  };
  card.append(button);
  if (draggable && !task.inspection_id) {
    card.draggable = true;
    card.ondragstart = event => event.dataTransfer.setData('text/plain', String(task.id));
  }
  return card;
}

async function saveTask(task, values) {
  if (!task) return take(db.from('stage_tasks').insert(values).select('id').single());
  return take(db.from('stage_tasks').update(values).eq('id', task.id)
    .eq('updated_at', task.updated_at).select('id').single());
}

async function renderTasks() {
  app.innerHTML = '<h1>Мої завдання</h1><button class="primary full" id="add-task">Створити завдання</button>'
    + '<label>Вигляд<select id="task-mode"><option value="active">Список</option><option value="board">Kanban</option>'
    + '<option value="calendar">Календар</option><option value="archive">Виконані</option></select></label>'
    + '<label>Пошук<input type="search" id="task-query"></label><div id="task-results" aria-live="polite">Завантаження…</div>';
  const results = app.querySelector('#task-results');
  const mode = app.querySelector('#task-mode');
  const query = app.querySelector('#task-query');
  mode.value = taskMode;
  app.querySelector('#add-task').onclick = () => taskForm();
  try {
    const tasks = await readTasks();
    if (!results.isConnected) return;
    const renderResults = () => {
      taskMode = mode.value;
      const term = query.value.trim().toLocaleLowerCase('uk');
      const filtered = tasks.filter(task => (taskMode === 'archive' ? task.status === 'done' :
        taskMode === 'board' || task.status !== 'done') &&
        [task.title, task.description, taskNumber(task.id)].join(' ').toLocaleLowerCase('uk').includes(term));
      results.replaceChildren();

      if (taskMode === 'board') {
        for (const [status, label] of Object.entries(taskStatuses)) {
          const section = document.createElement('section');
          section.className = 'task-column';
          const heading = document.createElement('h2');
          heading.textContent = label;
          section.append(heading);
          filtered.filter(task => task.status === status).forEach(task => section.append(taskCard(task, true)));
          section.ondragover = event => event.preventDefault();
          section.ondrop = async event => {
            event.preventDefault();
            const task = tasks.find(item => String(item.id) === event.dataTransfer.getData('text/plain'));
            if (!task || task.inspection_id || task.status === status) return;
            try { await saveTask(task, { status }); } catch (error) { fail(error); }
            if (page === 'tasks') await renderTasks();
          };
          results.append(section);
        }
        return;
      }
      if (taskMode === 'calendar') {
        renderTaskWeek(results, filtered, true);
        return;
      }
      filtered.forEach(task => results.append(taskCard(task)));
      if (!filtered.length) results.textContent = 'Немає завдань за цими параметрами.';
    };
    mode.onchange = query.oninput = renderResults;
    renderResults();
  } catch (error) {
    if (results.isConnected) results.textContent = 'Не вдалося завантажити завдання.';
    fail(error);
  }
}

function localDateValue(value) {
  if (!value) return '';
  const date = new Date(value);
  return new Date(+date - date.getTimezoneOffset() * 60000).toISOString().slice(0, 16);
}

function taskForm(task, date) {
  const options = (values, selected) => Object.entries(values).map(([key,label]) =>
    `<option value="${key}" ${selected === key ? 'selected' : ''}>${label}</option>`).join('');
  form(task ? taskNumber(task.id) : 'Нове завдання', `
    <label>Назва<input name="title" maxlength="180" required value="${esc(task?.title)}"></label>
    <label>Опис<textarea name="description" maxlength="8000">${esc(task?.description)}</textarea></label>
    <label>Пріоритет<select name="priority">${options(taskPriorities, task?.priority || 'medium')}</select></label>
    ${task ? `<label>Статус<select name="status">${options(taskStatuses,task.status)}</select></label>` : ''}
    <label>Початок<input type="datetime-local" name="start" value="${localDateValue(task?.starts_at || date)}"></label>
    <label>Строк<input type="datetime-local" name="due" value="${localDateValue(task?.due_at)}"></label>`,
  async data => {
    const iso = field => data.get(field) ? new Date(data.get(field)).toISOString() : null;
    try {
      const values = { title: data.get('title').trim(), description: data.get('description').trim(),
        priority: data.get('priority'), starts_at: iso('start'), due_at: iso('due') };
      if (task) values.status = data.get('status');
      await saveTask(task, values);
      return true;
    } catch (error) {
      fail(error);
      return false;
    }
  });
}

function renderTaskWeek(container, tasks, allowCreate = false) {
  let selected = new Date();
  let week = new Date(selected);
  week.setDate(week.getDate() - (week.getDay() + 6) % 7);
  const controls = document.createElement('div');
  controls.className = 'task-week';
  const agenda = document.createElement('div');
  container.append(controls, agenda);

  const draw = () => {
    controls.replaceChildren();
    for (let dayIndex = 0; dayIndex < 7; dayIndex++) {
      const day = new Date(week);
      day.setDate(day.getDate() + dayIndex);
      const button = document.createElement('button');
      button.textContent = day.toLocaleDateString('uk-UA', { weekday: 'short', day: 'numeric' });
      button.setAttribute('aria-pressed', String(day.toDateString() === selected.toDateString()));
      button.onclick = () => { selected = day; draw(); };
      controls.append(button);
    }
    agenda.replaceChildren();
    const dayTasks = tasks.filter(task => [task.starts_at, task.due_at].some(value =>
      value && new Date(value).toDateString() === selected.toDateString()));
    dayTasks.forEach(task => agenda.append(taskCard(task)));
    if (!dayTasks.length) agenda.append(document.createTextNode('На цей день немає завдань.'));
    if (allowCreate) {
      const add = document.createElement('button');
      add.className = 'full';
      add.textContent = 'Створити завдання на цю дату';
      add.onclick = () => taskForm(null, selected.toISOString());
      agenda.append(add);
    }
  };
  if (allowCreate) {
    for (const [label, delta] of [['Попередній тиждень', -7], ['Наступний тиждень', 7]]) {
      const button = document.createElement('button');
      button.textContent = label;
      button.onclick = () => {
        week.setDate(week.getDate() + delta);
        selected = new Date(week);
        draw();
      };
      container.insertBefore(button, controls);
    }
  }
  draw();
}

async function loadTaskHome(section) {
  try {
    const tasks = (await readTasks()).filter(task => task.status !== 'done');
    if (!section.isConnected) return;
    renderTaskWeek(section, tasks);
    const overdue = tasks.filter(taskOverdue);
    if (overdue.length) {
      const heading = document.createElement('h2');
      heading.textContent = 'Прострочені завдання';
      section.append(heading);
      overdue.slice(0, 3).forEach(task => section.append(taskCard(task)));
    }
  } catch (error) {
    if (section.isConnected) section.textContent = 'Не вдалося оновити персональний календар.';
  }
}
