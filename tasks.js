'use strict';

const taskStatuses = {
  planned: 'Заплановано', todo: 'До виконання', doing: 'В роботі',
  review: 'На перевірці', done: 'Виконано', blocked: 'Заблоковано'
};
const taskPriorities = { critical: 'Критичний', high: 'Високий', medium: 'Середній', low: 'Низький' };
const taskDate = value => value ? new Date(value).toLocaleString('uk-UA') : '';
const taskNumber = id => 'SB-' + String(id).padStart(3, '0');
let taskMode = 'active';
let taskQuickFilter = 'all';
let taskBoardScroll = 0;
let calendarMode = 'week';
let calendarDate = new Date();

async function readTasks() {
  const items = [];
  for (let start = 0; ; start += 100) {
    const batch = await take(db.from('stage_tasks')
      .select('id,owner_id,assigned_by,show_id,title,description,priority,status,starts_at,due_at,updated_at')
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
  card.dataset.status = task.status;
  const open = document.createElement('button');
  open.className = 'task-card-open';
  const initials = (me?.full_name || '').trim().split(/\s+/).slice(0, 2).map(part => part[0] || '').join('');
  open.innerHTML = `<span class="task-card-id"><small>${esc(taskNumber(task.id))}</small>
    ${initials ? `<span class="task-avatar" title="${esc(me.full_name)}" aria-label="${esc(me.full_name)}">${esc(initials)}</span>` : ''}</span><strong>${esc(task.title)}</strong>
    <span class="task-card-meta">
      <span class="task-status">${esc(taskStatuses[task.status])}</span>
      <span>${esc(taskPriorities[task.priority])}</span>
      ${task.due_at ? `<span>${esc(taskDate(task.due_at))}</span>` : ''}
      ${taskOverdue(task) ? '<span class="task-overdue">Прострочено</span>' : ''}
    </span>`;
  open.onclick = () => openStageTask(task);
  card.append(open);
  const details = document.createElement('button');
  details.className = 'full';
  details.textContent = 'Обговорення та історія';
  details.onclick = () => openTaskDetails(task);
  card.append(details);
  if (draggable && !task.assigned_by) {
    card.draggable = true;
    card.ondragstart = event => {
      event.dataTransfer.effectAllowed = 'move';
      event.dataTransfer.setData('application/x-stage-task', String(task.id));
    };
    const status = document.createElement('select');
    status.className = 'task-status-select';
    status.setAttribute('aria-label', 'Змінити статус ' + taskNumber(task.id));
    for (const [value, label] of Object.entries(taskStatuses)) status.add(new Option(label, value));
    status.value = task.status;
    status.onchange = async () => {
      status.disabled = true;
      try { await saveTask(task, { status: status.value }); }
      catch (error) { fail(error); }
      if (page === 'tasks') await renderTasks();
    };
    status.ondragstart = event => event.preventDefault();
    card.append(status);
  }
  return card;
}

async function saveTask(task, values) {
  if (!task) return take(db.from('stage_tasks').insert(values).select('id').single());
  return take(db.from('stage_tasks').update(values).eq('id', task.id)
    .eq('updated_at', task.updated_at).select('id').single());
}

async function renderTasks() {
  const previousBoard = app.querySelector('.task-board');
  if (previousBoard) taskBoardScroll = previousBoard.scrollLeft;
  const modes = { active: 'Список', board: 'Дошка', calendar: 'Календар', archive: 'Виконані' };
  const quickFilters = { all: 'Усі терміни', today: 'На сьогодні', overdue: 'Прострочені',
    soon: 'Найближчі', noDeadline: 'Без дедлайну' };
  const timeMatch = task => {
    const now = new Date();
    const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    const tomorrow = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1);
    const upcoming = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 8);
    const due = task.due_at ? new Date(task.due_at) : null;
    const start = task.starts_at ? new Date(task.starts_at) : null;
    switch (taskQuickFilter) {
      case 'today': return Boolean((due && due >= today && due < tomorrow) ||
        (start && start < tomorrow && (due || start) >= today));
      case 'overdue': return taskOverdue(task);
      case 'soon': return Boolean(due && due >= tomorrow && due < upcoming);
      case 'noDeadline': return !due;
      default: return true;
    }
  };
  app.innerHTML = `
    <div class="task-heading"><h1>Завдання</h1><button class="primary" id="add-task">Нове завдання</button></div>
    ${canManageTeamTasks() ? '<button class="full" id="team-task-create" type="button">Призначити командне завдання</button>' : ''}
    <div class="task-views" role="group" aria-label="Вигляд завдань">
      ${Object.entries(modes).map(([value, label]) => `<button type="button" data-mode="${value}">${label}</button>`).join('')}
    </div>
    <div class="task-quick" role="group" aria-label="Терміни завдань">
      ${Object.entries(quickFilters).map(([value, label]) => `<button type="button" data-quick="${value}">${label}</button>`).join('')}
    </div>
    <details class="task-filter-panel"><summary>Фільтри <output id="task-filter-count" aria-label="Активні фільтри"></output></summary>
    <div class="task-filters">
      <label>Пошук<input type="search" id="task-query" placeholder="Назва або номер"></label>
      <label>Статус<select id="task-filter-status"><option value="">Усі</option>
        ${Object.entries(taskStatuses).map(([key, label]) => `<option value="${key}">${label}</option>`).join('')}
      </select></label>
      <label>Пріоритет<select id="task-priority"><option value="">Усі</option>
        ${Object.entries(taskPriorities).map(([key, label]) => `<option value="${key}">${label}</option>`).join('')}
      </select></label>
    </div>
    </details>
    <div id="task-results" aria-live="polite">Завантаження…</div>`;
  const results = app.querySelector('#task-results');
  const modesButtons = [...app.querySelectorAll('[data-mode]')];
  const quickButtons = [...app.querySelectorAll('[data-quick]')];
  const query = app.querySelector('#task-query');
  const statusFilter = app.querySelector('#task-filter-status');
  const priority = app.querySelector('#task-priority');
  app.querySelector('#add-task').onclick = () => taskForm();
  const assignButton = app.querySelector('#team-task-create');
  if (assignButton) assignButton.onclick = teamTaskForm;
  try {
    const tasks = await readTasks();
    if (!results.isConnected) return;
    let bookings = [];
    const renderResults = () => {
      const boardPosition = results.classList.contains('task-board') ? results.scrollLeft : taskBoardScroll;
      quickButtons.forEach(button => button.setAttribute('aria-pressed', String(button.dataset.quick === taskQuickFilter)));
      modesButtons.forEach(button => button.setAttribute('aria-pressed', String(button.dataset.mode === taskMode)));
      results.classList.toggle('task-board', taskMode === 'board');
      const term = query.value.trim().toLocaleLowerCase('uk');
      const count = [term, priority.value, statusFilter.value, taskQuickFilter !== 'all'].filter(Boolean).length;
      const filterCount = app.querySelector('#task-filter-count');
      filterCount.textContent = count;
      filterCount.hidden = count === 0;
      const filtered = tasks.filter(task => (taskMode === 'archive' ? task.status === 'done' :
        taskMode === 'board' || taskMode === 'calendar' || task.status !== 'done') && timeMatch(task) &&
        (!statusFilter.value || task.status === statusFilter.value) && (!priority.value || task.priority === priority.value) &&
        [task.title, task.description, taskNumber(task.id), 'STG-' + String(task.id).padStart(4, '0')].join(' ').toLocaleLowerCase('uk').includes(term));
      results.replaceChildren();

      if (taskMode === 'board') {
        for (const [status, label] of Object.entries(taskStatuses)) {
          const section = document.createElement('section');
          section.className = 'task-column';
          const heading = document.createElement('h2');
          section.dataset.status = status;
          section.dataset.column = status;
          const matches = filtered.filter(task => task.status === status);
          heading.textContent = label + ' · ' + matches.length;
          section.append(heading);
          matches.forEach(task => section.append(taskCard(task, true)));
          section.ondragover = event => {
            if (event.dataTransfer.types.includes('application/x-stage-task')) event.preventDefault();
          };
          section.ondrop = async event => {
            event.preventDefault();
            const task = tasks.find(item => String(item.id) === event.dataTransfer.getData('application/x-stage-task'));
            if (!task || task.status === status) return;
            try { await saveTask(task, { status }); } catch (error) { fail(error); }
            if (page === 'tasks') await renderTasks();
          };
          results.append(section);
        }
        results.scrollLeft = boardPosition;
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
    quickButtons.forEach(button => { button.onclick = () => {
      taskQuickFilter = button.dataset.quick;
      renderResults();
    }; });
    query.oninput = priority.onchange = statusFilter.onchange = renderResults;
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

function openStageTask(task) {
  if (task.assigned_by) openAssignedTask(task);
  else taskForm(task);
}

function taskForm(task, date) {
  const options = (values, selected) => Object.entries(values).map(([key,label]) =>
    `<option value="${key}" ${selected === key ? 'selected' : ''}>${label}</option>`).join('');
  form(task ? taskNumber(task.id) : 'Нове завдання', `
    <label>Назва<input name="title" maxlength="180" required value="${esc(task?.title)}"></label>
    ${task ? `<label>Статус<select name="status">${options(taskStatuses,task.status)}</select></label>` : ''}
    <label>Опис<textarea name="description" maxlength="8000">${esc(task?.description)}</textarea></label>
    <div class="task-format" role="group" aria-label="Форматування опису">
      <button type="button" data-format="bold">Жирний</button>
      <button type="button" data-format="list">Список</button>
      <button type="button" data-format="preview" aria-pressed="false">Перегляд</button>
    </div><div class="task-description-preview" hidden></div>
    <label>Пріоритет<select name="priority">${options(taskPriorities, task?.priority || 'medium')}</select></label>

    <label>Дедлайн<input type="datetime-local" name="due" value="${localDateValue(task?.due_at)}"></label>
    <details class="task-more" ${date ? 'open' : ''}><summary>Додаткові параметри</summary>
    <label>Початок<input type="datetime-local" name="start" value="${localDateValue(task?.starts_at || date)}"></label></details>`,
  async data => {
    const iso = (field, original) => {
      const value = data.get(field);
      if (!value) return null;
      if (original && value === localDateValue(original)) return original;
      return new Date(value).toISOString();
    };
    try {
      const values = { title: data.get('title').trim(), description: data.get('description').trim(),
        priority: data.get('priority'), starts_at: iso('start', task?.starts_at || date), due_at: iso('due', task?.due_at) };
      if (task) values.status = data.get('status');
      await saveTask(task, values);
      return true;
    } catch (error) {
      fail(error);
      return false;
    }
  });
  modal.classList.add('task-editor');
  const viewport = window.visualViewport;
  const fitEditor = () => {
    if (!viewport || viewport.scale !== 1) return;
    modal.style.setProperty('--editor-top', viewport.offsetTop + 'px');
    modal.style.setProperty('--editor-height', viewport.height + 'px');
  };
  fitEditor();
  viewport?.addEventListener('resize', fitEditor);
  viewport?.addEventListener('scroll', fitEditor);
  modal.addEventListener('close', () => {
    viewport?.removeEventListener('resize', fitEditor);
    viewport?.removeEventListener('scroll', fitEditor);
    modal.classList.remove('task-editor');
    modal.style.removeProperty('--editor-top');
    modal.style.removeProperty('--editor-height');
  }, { once: true });
  const description = modal.querySelector('[name=description]');
  const preview = modal.querySelector('.task-description-preview');
  const markup = text => esc(text).replace(/\*\*([^*\n]+)\*\*/g, '<strong>$1</strong>');
  const refresh = () => {
    preview.innerHTML = description.value.split('\n').map(line =>
      line.startsWith('- ') ? '<div>• ' + markup(line.slice(2)) + '</div>' : '<div>' + markup(line || ' ') + '</div>'
    ).join('');
  };
  description.addEventListener('input', refresh);
  for (const toolbarButton of modal.querySelectorAll('[data-format]')) {
    toolbarButton.onclick = () => {
      if (toolbarButton.dataset.format === 'preview') {
        preview.hidden = !preview.hidden;
        toolbarButton.setAttribute('aria-pressed', String(!preview.hidden));
        if (!preview.hidden) refresh();
        return;
      }
      const start = description.selectionStart;
      const end = description.selectionEnd;
      const selection = description.value.slice(start, end);
      const replacement = toolbarButton.dataset.format === 'bold' ? '**' + (selection || 'текст') + '**'
        : (start && description.value[start - 1] !== '\n' ? '\n' : '') + '- ' + (selection || 'пункт');
      if (description.value.length - selection.length + replacement.length > description.maxLength) return;
      description.setRangeText(replacement, start, end, 'select');
      description.focus();
      refresh();
    };
  }
}

function dateShift(date, days) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate() + days, 12);
}

function renderTaskCalendar(container, tasks, { full = false, bookings = [] } = {}) {
  let selected = full ? calendarDate : new Date();
  let mode = full ? calendarMode : 'week';
  const modeLabels = { day: 'День', week: 'Тиждень', month: 'Місяць', year: 'Рік' };
  const views = document.createElement('div');
  views.className = 'calendar-modes';
  views.setAttribute('role', 'group');
  views.setAttribute('aria-label', 'Режим календаря');
  const navigation = document.createElement('div');
  navigation.className = 'calendar-navigation';
  const controls = document.createElement('div');
  controls.className = 'task-week';
  const agenda = document.createElement('div');
  const timeline = document.createElement('div');
  timeline.className = 'calendar-timeline';
  const title = document.createElement('strong');
  const button = (label, onclick) => {
    const element = document.createElement('button');
    element.type = 'button';
    element.textContent = label;
    element.onclick = onclick;
    return element;
  };

  function navigate(delta) {
    if (mode === 'month' || mode === 'year') {
      const first = new Date(selected.getFullYear(), selected.getMonth() + delta * (mode === 'year' ? 12 : 1), 1, 12);
      const last = new Date(first.getFullYear(), first.getMonth() + 1, 0).getDate();
      selected = dateShift(first, Math.min(last, selected.getDate()) - 1);
    } else {
      selected = dateShift(selected, delta * (mode === 'week' ? 7 : 1));
    }
    draw();
  }

  const datePicker = document.createElement('input');
  datePicker.type = 'date';
  datePicker.setAttribute('aria-label', 'Перейти до дати');
  datePicker.onchange = () => {
    if (!datePicker.value) return;
    const next = new Date(datePicker.value + 'T12:00');
    if (!Number.isFinite(+next)) return;
    selected = next;
    draw();
  };
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
    const jump = document.createElement('div');
    jump.className = 'calendar-jump';
    jump.append(button('Сьогодні', () => { selected = new Date(); draw(); }), datePicker);
    container.append(views, navigation, jump);
  }
  container.append(controls, timeline, agenda);

  const dateLabel = day => day.toLocaleDateString('uk-UA', { dateStyle: 'full' });
  const sameDay = (first, second) => first.toDateString() === second.toDateString();
  const base = date => new Date(date.getFullYear(), date.getMonth(), 1, 12);
  const monday = date => dateShift(date, -(date.getDay() + 6) % 7);
  function entries(day, days = 1) {
    const start = new Date(day.getFullYear(), day.getMonth(), day.getDate());
    const end = new Date(day.getFullYear(), day.getMonth(), day.getDate() + days);
    return {
      due: tasks.filter(task => {
        if (!task.starts_at && !task.due_at) return false;
        const first = new Date(task.starts_at || task.due_at);
        const last = new Date(task.due_at || task.starts_at);
        return first < end && last >= start;
      }),
      reserved: bookings.filter(item => new Date(item.start_date) < end && new Date(item.end_date) > start)
    };
  }

  function addDateDrop(cell, day) {
    cell.ondragover = event => {
      if (event.dataTransfer.types.includes('application/x-stage-task')) event.preventDefault();
    };
    cell.ondrop = async event => {
      event.preventDefault();
      const task = tasks.find(item => String(item.id) === event.dataTransfer.getData('application/x-stage-task'));
      if (!task || (!task.starts_at && !task.due_at)) return;
      const original = new Date(task.starts_at || task.due_at);
      const dateIndex = date => Date.UTC(date.getFullYear(), date.getMonth(), date.getDate()) / 86400000;
      const change = dateIndex(day) - dateIndex(original);
      if (!change) return;
      const shift = value => {
        if (!value) return null;
        const next = new Date(value);
        next.setDate(next.getDate() + change);
        return next.toISOString();
      };
      try {
        await saveTask(task, { starts_at: shift(task.starts_at), due_at: shift(task.due_at) });
        calendarDate = day;
      } catch (error) { fail(error); }
      if (page === 'tasks') await renderTasks();
    };
  }

  function drawTimeline(first, days) {
    timeline.classList.toggle('calendar-timeline-week', days === 7);
    const now = new Date();
    let currentHour;
    if (days === 7) {
      const rail = document.createElement('div');
      rail.className = 'calendar-hour-rail';
      rail.setAttribute('aria-hidden', 'true');
      rail.append(document.createElement('div'));
      for (let hour = 0; hour < 24; hour++) {
        const label = document.createElement('div');
        label.textContent = String(hour).padStart(2, '0') + ':00';
        rail.append(label);
      }
      const spans = document.createElement('div');
      spans.className = 'calendar-multiday';
      const week = Array.from({ length: days }, (_, index) => dateShift(first, index));
      const dayKey = value => localDateValue(value).slice(0, 10);
      for (const task of tasks) {
        if (!task.starts_at || !task.due_at) continue;
        const starts = dayKey(task.starts_at);
        const ends = dayKey(task.due_at);
        if (starts >= ends) continue;
        const covered = week.map(dayKey).map((key, index) => key >= starts && key <= ends ? index : -1)
          .filter(index => index >= 0);
        if (!covered.length) continue;
        const entry = button(task.title, () => openStageTask(task));
        entry.style.gridColumn = (covered[0] + 2) + ' / span ' + covered.length;
        spans.append(entry);
      }
      if (spans.childElementCount) timeline.append(spans);
      timeline.append(rail);
    }
    for (let index = 0; index < days; index++) {
      const day = dateShift(first, index);
      const start = new Date(day.getFullYear(), day.getMonth(), day.getDate());
      const end = new Date(day.getFullYear(), day.getMonth(), day.getDate() + 1);
      const column = document.createElement('section');
      const heading = document.createElement('h3');
      heading.textContent = day.toLocaleDateString('uk-UA', { weekday: 'short', day: 'numeric' });
      heading.className = 'calendar-day-heading';
      column.append(heading);
      // Iterate real elapsed hours so DST days contain 23 or 25 slots.
      const { due, reserved } = entries(day);
      for (let instant = +start; instant < +end; instant += 3600000) {
        const time = new Date(instant);
        const label = time.toLocaleTimeString('uk-UA', { hour: '2-digit', minute: '2-digit' });
        const row = document.createElement('div');
        row.className = 'calendar-hour';
        const add = button(days === 7 ? '' : label, () => taskForm(null, time.toISOString()));
        add.className = 'calendar-slot';
        if (+now >= instant && +now < instant + 3600000) {
          currentHour = row;
          const marker = document.createElement('span');
          marker.className = 'calendar-now';
          marker.style.top = ((+now - instant) / 3600000 * 100) + '%';
          marker.setAttribute('aria-label', 'Поточний час');
          row.append(marker);
        }
        add.setAttribute('aria-label', 'Нове завдання · ' + dateLabel(day) + ' · ' + label +
          ' · ' + time.toLocaleTimeString('uk-UA', { timeZoneName: 'shortOffset' }).split(' ').at(-1));
        row.append(add);
        const within = value => value && +new Date(value) >= instant && +new Date(value) < instant + 3600000;
        for (const task of due) {
          if (!within(task.starts_at) && !within(task.due_at)) continue;
          const entry = button((within(task.due_at) ? 'Строк · ' : '') + task.title, () => openStageTask(task));
          entry.className = 'calendar-hour-entry';
          row.append(entry);
        }
        for (const booking of reserved) {
          if (!within(booking.start_date)) continue;
          const entry = button('Бронювання · ' + booking.show_name, () => go('reservations'));
          entry.className = 'calendar-hour-entry';
          row.append(entry);
        }
        column.append(row);
      }
      timeline.append(column);
    }
    timeline.scrollTop = 0;
    if (currentHour) requestAnimationFrame(() => {
      if (!currentHour.isConnected) return;
      timeline.scrollTop = Math.max(0, currentHour.getBoundingClientRect().top -
        timeline.getBoundingClientRect().top + timeline.scrollTop - 90);
    });
  }

  function draw() {
    if (full) {
      calendarDate = selected;
      calendarMode = mode;
      datePicker.value = localDateValue(selected).slice(0,10);
      for (const view of views.children) view.setAttribute('aria-pressed', String(view.dataset.calendarMode === mode));
    }
    const first = mode === 'month' ? monday(base(selected)) : monday(selected);
    const count = mode === 'day' || mode === 'year' ? 0 : mode === 'week' ? 7 : 42;
    title.textContent = mode === 'day' ? dateLabel(selected)
      : mode === 'week' ? first.toLocaleDateString('uk-UA') + ' – ' + dateShift(first, 6).toLocaleDateString('uk-UA')
      : mode === 'year' ? String(selected.getFullYear()) : selected.toLocaleDateString('uk-UA', { month: 'long', year: 'numeric' });
    controls.replaceChildren();
    controls.classList.toggle('calendar-year', mode === 'year');
    if (full && mode === 'month') {
      for (let offset = 0; offset < 7; offset++) {
        const weekday = document.createElement('span');
        weekday.className = 'calendar-weekday';
        weekday.textContent = dateShift(first, offset).toLocaleDateString('uk-UA', { weekday: 'short' });
        controls.append(weekday);
      }
    }
    timeline.replaceChildren();
    if (mode === 'year') {
      for (let month = 0; month < 12; month++) {
        const day = new Date(selected.getFullYear(), month, 1, 12);
        const days = new Date(selected.getFullYear(), month + 1, 0).getDate();
        const { due, reserved } = entries(day, days);
        const title = day.toLocaleDateString('uk-UA', { month: 'long' });
        controls.append(button(title + ' · ' + (due.length + reserved.length), () => {
          selected = day; mode = 'month'; draw();
        }));
      }
    }
    for (let index = 0; index < count; index++) {
      const day = dateShift(first, index);
      const { due, reserved } = entries(day);
      const cell = button(mode === 'month' ? String(day.getDate())
        : day.toLocaleDateString('uk-UA', { weekday: 'short', day: 'numeric' }), () => { selected = day; draw(); });
      cell.setAttribute('aria-label', dateLabel(day) + ' · Подій: ' + (due.length + reserved.length));
      cell.setAttribute('aria-pressed', String(sameDay(day, selected)));
      if (sameDay(day, new Date())) cell.setAttribute('aria-current', 'date');
      cell.classList.toggle('calendar-outside', mode === 'month' && day.getMonth() !== selected.getMonth());
      cell.classList.toggle('calendar-has-events', due.length + reserved.length > 0);
      if (full) addDateDrop(cell, day);
      controls.append(cell);
    }
    if (full && mode === 'day') drawTimeline(selected, 1);
    if (full && mode === 'week') drawTimeline(first, 7);
    agenda.replaceChildren();
    const heading = document.createElement('h3');
    heading.textContent = dateLabel(selected);
    agenda.append(heading);
    const { due, reserved } = entries(selected);
    due.forEach(task => agenda.append(taskCard(task, full)));
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
      const undated = tasks.filter(task => !task.starts_at && !task.due_at && task.status !== 'done');
      if (undated.length) {
        const backlog = document.createElement('details');
        backlog.className = 'task-more';
        const label = document.createElement('summary');
        label.textContent = 'Без дати · ' + undated.length;
        backlog.append(label, ...undated.map(task => taskCard(task, false)));
        agenda.append(backlog);
      }
    }
  }
  draw();
}
