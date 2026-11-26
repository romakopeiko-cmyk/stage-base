'use strict';

const taskStatuses = {
  planned: 'Заплановано', todo: 'До виконання', doing: 'В роботі',
  review: 'На перевірці', done: 'Виконано', blocked: 'Заблоковано'
};
const taskPriorities = { critical: 'Критичний', high: 'Високий', medium: 'Середній', low: 'Низький' };
const taskDate = value => value ? new Date(value).toLocaleString('uk-UA') : '';
const taskNumber = id => 'STG-' + String(id).padStart(4, '0');
let taskMode = 'active';
let calendarMode = 'week';
let calendarDate = new Date();

async function readTasks() {
  const items = [];
  for (let start = 0; ; start += 100) {
    const batch = await take(db.from('stage_tasks')
      .select('id,title,description,priority,status,starts_at,due_at,updated_at')
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
  card.className = 'card task-card';
  card.dataset.priority = task.priority;
  const open = document.createElement('button');
  open.className = 'task-card-open';
  open.innerHTML = `<small>${esc(taskNumber(task.id))}</small><strong>${esc(task.title)}</strong>
    <span class="task-card-meta">
      <span>${esc(taskStatuses[task.status])}</span>
      <span>${esc(taskPriorities[task.priority])}</span>
      ${task.due_at ? `<span>${esc(taskDate(task.due_at))}</span>` : ''}
      ${taskOverdue(task) ? '<span class="task-overdue">Прострочено</span>' : ''}
    </span>`;
  open.onclick = () => taskForm(task);
  card.append(open);
  if (draggable) {
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
  const modes = { active: 'Список', board: 'Дошка', calendar: 'Календар', archive: 'Виконані' };
  app.innerHTML = `
    <div class="task-heading"><h1>Завдання</h1><button class="primary" id="add-task">Нове завдання</button></div>
    <div class="task-views" role="group" aria-label="Вигляд завдань">
      ${Object.entries(modes).map(([value, label]) => `<button type="button" data-mode="${value}">${label}</button>`).join('')}
    </div>
    <div class="task-filters">
      <label>Пошук<input type="search" id="task-query" placeholder="Назва або номер"></label>
      <label>Пріоритет<select id="task-priority"><option value="">Усі</option>
        ${Object.entries(taskPriorities).map(([key, label]) => `<option value="${key}">${label}</option>`).join('')}
      </select></label>
    </div>
    <div id="task-results" aria-live="polite">Завантаження…</div>`;
  const results = app.querySelector('#task-results');
  const modesButtons = [...app.querySelectorAll('[data-mode]')];
  const query = app.querySelector('#task-query');
  const priority = app.querySelector('#task-priority');
  app.querySelector('#add-task').onclick = () => taskForm();
  try {
    const tasks = await readTasks();
    if (!results.isConnected) return;
    let bookings = [];
    const renderResults = () => {
      modesButtons.forEach(button => button.setAttribute('aria-pressed', String(button.dataset.mode === taskMode)));
      results.classList.toggle('task-board', taskMode === 'board');
      const term = query.value.trim().toLocaleLowerCase('uk');
      const filtered = tasks.filter(task => (taskMode === 'archive' ? task.status === 'done' :
        taskMode === 'board' || task.status !== 'done') &&
        (!priority.value || task.priority === priority.value) &&
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
            if (!task || task.status === status) return;
            try { await saveTask(task, { status }); } catch (error) { fail(error); }
            if (page === 'tasks') await renderTasks();
          };
          results.append(section);
        }
        return;
      }
      if (taskMode === 'calendar') {
        renderTaskCalendar(results, filtered, { full: true, bookings });
        return;
      }
      filtered.forEach(task => results.append(taskCard(task)));
      if (!filtered.length) results.textContent = 'Немає завдань за цими параметрами.';
    };
    modesButtons.forEach(button => {
      button.onclick = () => { taskMode = button.dataset.mode; renderResults(); };
    });
    query.oninput = priority.onchange = renderResults;
    renderResults();
    take(db.rpc('stage_list_reservations')).then(data => {
      bookings = data.reservations.filter(item => ['approved', 'issued'].includes(item.status));
      if (results.isConnected && taskMode === 'calendar') renderResults();
    }).catch(() => {
      if (results.isConnected && taskMode === 'calendar') toast('Не вдалося завантажити бронювання.');
    });
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

function dateShift(date, days) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate() + days, 12);
}

function renderTaskCalendar(container, tasks, { full = false, bookings = [] } = {}) {
  let selected = full ? calendarDate : new Date();
  let mode = full ? calendarMode : 'week';
  const modeLabels = { day: 'День', week: 'Тиждень', month: 'Місяць' };
  const views = document.createElement('div');
  views.className = 'calendar-modes';
  views.setAttribute('role', 'group');
  views.setAttribute('aria-label', 'Режим календаря');
  const navigation = document.createElement('div');
  navigation.className = 'calendar-navigation';
  const controls = document.createElement('div');
  controls.className = 'task-week';
  const agenda = document.createElement('div');
  const title = document.createElement('strong');
  const button = (label, onclick) => {
    const element = document.createElement('button');
    element.type = 'button';
    element.textContent = label;
    element.onclick = onclick;
    return element;
  };

  function navigate(delta) {
    if (mode === 'month') {
      const first = new Date(selected.getFullYear(), selected.getMonth() + delta, 1, 12);
      const last = new Date(first.getFullYear(), first.getMonth() + 1, 0).getDate();
      selected = dateShift(first, Math.min(last, selected.getDate()) - 1);
    } else {
      selected = dateShift(selected, delta * (mode === 'week' ? 7 : 1));
    }
    draw();
  }

  if (full) {
    for (const [value, label] of Object.entries(modeLabels)) {
      const view = button(label, () => { mode = value; draw(); });
      view.dataset.calendarMode = value;
      views.append(view);
    }
    const previous = button('‹', () => navigate(-1));
    previous.setAttribute('aria-label', 'Попередній період');
    const next = button('›', () => navigate(1));
    next.setAttribute('aria-label', 'Наступний період');
    navigation.append(previous, title, next);
    container.append(views, navigation);
  }
  container.append(controls, agenda);

  const dateLabel = day => day.toLocaleDateString('uk-UA', { dateStyle: 'full' });
  const sameDay = (first, second) => first.toDateString() === second.toDateString();
  const base = date => new Date(date.getFullYear(), date.getMonth(), 1, 12);
  const monday = date => dateShift(date, -(date.getDay() + 6) % 7);
  function entries(day) {
    const start = new Date(day.getFullYear(), day.getMonth(), day.getDate());
    const end = new Date(day.getFullYear(), day.getMonth(), day.getDate() + 1);
    return {
      due: tasks.filter(task => [task.starts_at, task.due_at].some(value => value && sameDay(day, new Date(value)))),
      reserved: bookings.filter(item => new Date(item.start_date) < end && new Date(item.end_date) > start)
    };
  }

  function draw() {
    if (full) {
      calendarDate = selected;
      calendarMode = mode;
      for (const view of views.children) view.setAttribute('aria-pressed', String(view.dataset.calendarMode === mode));
    }
    const first = mode === 'month' ? monday(base(selected)) : monday(selected);
    const count = mode === 'day' ? 0 : mode === 'week' ? 7 : 42;
    title.textContent = mode === 'day' ? dateLabel(selected)
      : mode === 'week' ? first.toLocaleDateString('uk-UA') + ' – ' + dateShift(first, 6).toLocaleDateString('uk-UA')
      : selected.toLocaleDateString('uk-UA', { month: 'long', year: 'numeric' });
    controls.replaceChildren();
    for (let index = 0; index < count; index++) {
      const day = dateShift(first, index);
      const { due, reserved } = entries(day);
      const cell = button(mode === 'month' ? String(day.getDate())
        : day.toLocaleDateString('uk-UA', { weekday: 'short', day: 'numeric' }), () => { selected = day; draw(); });
      cell.setAttribute('aria-label', dateLabel(day) + ' · Подій: ' + (due.length + reserved.length));
      cell.setAttribute('aria-pressed', String(sameDay(day, selected)));
      cell.classList.toggle('calendar-outside', mode === 'month' && day.getMonth() !== selected.getMonth());
      cell.classList.toggle('calendar-has-events', due.length + reserved.length > 0);
      controls.append(cell);
    }
    agenda.replaceChildren();
    const heading = document.createElement('h3');
    heading.textContent = dateLabel(selected);
    agenda.append(heading);
    const { due, reserved } = entries(selected);
    due.forEach(task => agenda.append(taskCard(task)));
    for (const item of reserved) {
      const card = document.createElement('button');
      card.className = 'full';
      card.textContent = 'Бронювання · ' + item.show_name;
      card.onclick = () => go('reservations');
      agenda.append(card);
    }
    if (!due.length && !reserved.length) agenda.append(document.createTextNode('На цей день немає подій.'));
    if (full) {
      const add = button('Створити завдання на цю дату', () => taskForm(null,
        new Date(selected.getFullYear(), selected.getMonth(), selected.getDate(), 9).toISOString()));
      add.className = 'full';
      agenda.append(add);
    }
  }
  draw();
}
