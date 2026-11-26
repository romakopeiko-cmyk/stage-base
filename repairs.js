'use strict';

const repairStatuses = {
  reported:'Заявка', scheduled:'Заплановано', in_progress:'У роботі',
  awaiting_inspection:'Очікує перевірки', completed:'Завершено', irreparable:'Невідновне', cancelled:'Скасовано'
};

async function renderRepairs() {
  app.innerHTML = '<h1>Ремонти</h1><div id="repair-content" aria-live="polite">Завантаження…</div>';
  const target = app.querySelector('#repair-content');
  const button = (label, action) => {
    const b = document.createElement('button');
    b.className = 'full';
    b.textContent = label;
    b.onclick = action;
    return b;
  };
  try {
    const data = await take(db.rpc('stage_list_repairs'));
    if (!target.isConnected) return;
    target.replaceChildren();
    if (data.can_report) target.append(button('Створити заявку', repairReportForm));
    if (!data.repairs.length) target.insertAdjacentHTML('beforeend', '<p>Немає доступних заявок.</p>');
    for (const item of data.repairs) {
      const card = document.createElement('article');
      card.className = 'card line';
      const deadline = new Date(item.deadline_at).toLocaleString('uk-UA');
      card.innerHTML = `<h2>${esc(item.asset)}</h2>
        <p>${esc(item.inventory_number)} · ${esc(repairStatuses[item.status] ?? item.status)}</p>
        <p>${esc(item.damage_description)}</p>
        <p>До ${esc(deadline)} · Відповідальний ${esc(item.responsible)}</p>
        ${item.project ? `<p>Проєкт ${esc(item.project)}</p>` : ''}
        ${item.executor_name ? `<p>Виконавець ${esc(item.executor_name)}</p>` : ''}
        ${item.repair_description ? `<p>${esc(item.repair_description)}</p>` : ''}`;
      if (data.can_manage) {
        if (item.status === 'reported') card.append(button('Призначити виконавця', () =>
          repairTransition(item, 'scheduled', 'Призначення виконавця', '<label>Виконавець<input name="executor" required maxlength="160"></label>')));
        if (item.status === 'scheduled') card.append(button('Почати ремонт', () =>
          repairTransition(item, 'in_progress', 'Початок ремонту', '<p>Підтвердіть початок робіт.</p>')));
        if (item.status === 'in_progress') card.append(button('Передати на перевірку', () =>
          repairTransition(item, 'awaiting_inspection', 'Передача на перевірку', '<label>Виконані роботи<textarea name="work" required maxlength="4000"></textarea></label>')));
      }
      target.append(card);
    }
  } catch (error) {
    if (target.isConnected) target.textContent = 'Не вдалося завантажити ремонти.';
    fail(error);
  }
}

function repairReportForm() {
  form('Заявка на ремонт', `<label>Майно<select name="asset" required><option value="">Оберіть майно</option>
      ${records.map(a => `<option value="${safeId(a.id)}">${esc(a.name)} · ${esc(a.inventory_number)}</option>`).join('')}
    </select></label>
    <label>Відповідальний проєкт<select name="project">${optionIds('shows')}</select></label>
    <label>Пошкодження<textarea name="damage" required maxlength="4000"></textarea></label>
    <label>Термін ремонту<input type="datetime-local" name="deadline" required></label>`,
    data => repairAction('stage_report_repair', {
      p_asset:data.get('asset'), p_project:data.get('project') || null, p_damage:data.get('damage'),
      p_deadline:new Date(data.get('deadline')).toISOString()
    }));
}

function repairTransition(item, status, title, content) {
  form(title, content, data => repairAction('stage_advance_repair', {
    p_repair:item.id, p_status:status, p_executor:data.get('executor'), p_work:data.get('work')
  }));
}

async function repairAction(name, args) {
  try {
    await take(db.rpc(name,args));
    toast('Зміни збережено');
    renderRepairs();
    return true;
  } catch (error) {
    fail(error);
    return false;
  }
}
