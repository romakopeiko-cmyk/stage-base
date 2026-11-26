'use strict';

const reservationStatuses = {
  pending: 'На погодженні', approved: 'Погоджено', rejected: 'Відмовлено',
  cancelled: 'Скасовано', issued: 'Видано', completed: 'Завершено'
};

async function renderReservations() {
  app.innerHTML = '<h1>Бронювання</h1><div id="reservations" aria-live="polite">Завантаження…</div>';
  const container = document.querySelector('#reservations');
  try {
    const result = await take(db.rpc('stage_list_reservations'));
    if (!container.isConnected) return;
    container.replaceChildren();
    if (result.can_create) {
      const create = document.createElement('button');
      create.type = 'button';
      create.className = 'primary full';
      create.textContent = 'Створити запит';
      create.onclick = () => reservationForm();
      container.append(create);
    }
    if (!result.reservations.length) {
      container.insertAdjacentHTML('beforeend', '<p>Бронювань поки немає.</p>');
    }
    const date = value => new Date(value).toLocaleString('uk-UA');
    for (const request of result.reservations) {
      const card = document.createElement('article');
      card.className = 'card line';
      card.innerHTML = `
        <h2>${esc(request.show_name)}</h2>
        <span class="badge">${esc(reservationStatuses[request.status])}</span>
        <p>${esc(date(request.start_date))} — ${esc(date(request.end_date))}</p>
        <p>Відповідальна особа — ${esc(request.responsible_name)}</p>
        ${request.purpose ? `<p>${esc(request.purpose)}</p>` : ''}
        ${request.items.length ? `<ul>${request.items.map(item =>
          `<li>${esc(item.name)} · ${esc(item.number)} · ${esc(item.quantity)} ${esc(item.unit)}</li>`).join('')}</ul>` : ''}
        ${request.rejection_reason ? `<p>${esc(request.rejection_reason)}</p>` : ''}`;
      for (const [allowed, approve, label] of [
        [request.can_approve, true, 'Погодити'], [request.can_reject, false, 'Відмовити']
      ]) {
        if (!allowed) continue;
        const button = document.createElement('button');
        button.type = 'button';
        button.className = approve ? 'primary full' : 'full';
        button.textContent = label;
        button.onclick = () => decideReservation(request.id, approve);
        card.append(button);
      }
      container.append(card);
    }
  } catch (error) {
    if (container.isConnected) container.textContent = 'Не вдалося завантажити бронювання.';
    fail(error);
  }
}

function reservationForm() {
  form('Запит на бронювання', `
    <label>Шоу<select id="reservation-show" name="show" required>${optionIds('shows')}</select></label>
    <label>Відповідальна особа<select id="reservation-responsible" name="responsible" required>
      <option value="">Спочатку оберіть шоу</option>
    </select></label>
    ${field('start', 'Початок', 'datetime-local')}
    ${field('end', 'Кінець', 'datetime-local')}
    ${field('purpose', 'Мета', 'text', false)}
    <div id="reservation-items"></div>
    <button type="button" class="full" id="reservation-add-item">Додати позицію</button>
  `, async data => {
    const start = new Date(data.get('start'));
    const end = new Date(data.get('end'));
    if (!Number.isFinite(+start) || !Number.isFinite(+end) || end <= start) {
      toast('Перевірте дати бронювання');
      return false;
    }
    const items = data.getAll('asset').map((asset_id, index) => ({
      asset_id, quantity: Number(data.getAll('amount')[index])
    }));
    try {
      await take(db.rpc('stage_create_reservation', {
        p_show: data.get('show'), p_responsible: data.get('responsible'),
        p_start: start.toISOString(), p_end: end.toISOString(), p_items: items,
        p_purpose: data.get('purpose')
      }));
      toast('Запит надіслано на погодження');
      return true;
    } catch (error) {
      fail(error);
      return false;
    }
  });

  const show = modal.querySelector('#reservation-show');
  const responsible = modal.querySelector('#reservation-responsible');
  let responsibleRequest = 0;
  show.onchange = async () => {
    const request = ++responsibleRequest;
    responsible.innerHTML = '<option value="">Оберіть відповідальну особу</option>';
    if (!show.value) return;
    try {
      const people = await take(db.rpc('stage_reservation_responsibles', { p_show: show.value }));
      if (request !== responsibleRequest || !responsible.isConnected) return;
      for (const person of people) responsible.add(new Option(person.name, person.id));
      if (people.some(person => person.id === me.id)) responsible.value = me.id;
    } catch (error) {
      if (request === responsibleRequest && responsible.isConnected) fail(error);
    }
  };

  const items = modal.querySelector('#reservation-items');
  const add = modal.querySelector('#reservation-add-item');
  const options = records.map(asset =>
    `<option value="${safeId(asset.id)}">${esc(asset.name)} · ${esc(asset.inventory_number)}</option>`).join('');
  function addItem() {
    const item = document.createElement('fieldset');
    item.className = 'line';
    item.innerHTML = `
      <label>Майно<select name="asset" required><option value="">Оберіть майно</option>${options}</select></label>
      <label>Кількість<input name="amount" type="number" min="0.001" step="any" value="1" required></label>`;
    if (items.childElementCount) {
      const remove = document.createElement('button');
      remove.type = 'button';
      remove.className = 'full';
      remove.textContent = 'Прибрати позицію';
      remove.onclick = () => item.remove();
      item.append(remove);
    }
    items.append(item);
  }
  add.onclick = addItem;
  addItem();
}

function decideReservation(id, approve) {
  form(approve ? 'Погодити бронювання' : 'Відмовити в бронюванні',
    approve ? '<p>Підтвердьте погодження запиту.</p>' : field('reason', 'Причина відмови'),
    async data => {
      try {
        await take(db.rpc('stage_decide_reservation', {
          p_reservation: id, p_approve: approve, p_reason: data.get('reason')
        }));
        toast(approve ? 'Бронювання погоджено' : 'Відмову збережено');
        return true;
      } catch (error) {
        fail(error);
        return false;
      }
    });
}
