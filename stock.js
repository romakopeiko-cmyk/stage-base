'use strict';

async function renderStock() {
  app.innerHTML = '<h1>Складські операції</h1><div id="stock-list" aria-live="polite">Завантаження…</div>';
  const list = app.querySelector('#stock-list');
  try {
    const data = await take(db.rpc('stage_list_stock'));
    if (!list.isConnected) return;
    list.replaceChildren();
    if (data.can_transfer) {
      const transfer = document.createElement('button');
      transfer.className = 'full';
      transfer.textContent = 'Перемістити між складами';
      transfer.onclick = stockTransferForm;
      list.append(transfer);
    }
    for (const reservation of data.approved) {
      const card = document.createElement('article');
      card.className = 'card line';
      card.innerHTML = `<h2>${esc(reservation.show)}</h2><p>Отримувач — ${esc(reservation.recipient)}</p>
        <ul>${(reservation.items || []).map(item => `<li>${esc(item.name)} · ${esc(item.number)} · ${esc(item.quantity)}</li>`).join('')}</ul>`;
      const issue = document.createElement('button');
      issue.className = 'primary full';
      issue.textContent = 'Видати за бронюванням';
      issue.onclick = () => stockIssueForm(reservation);
      card.append(issue);
      list.append(card);
    }
    const seen = new Set();
    for (const item of data.outstanding) {
      const card = document.createElement('article');
      card.className = 'card line';
      card.innerHTML = `<h2>${esc(item.name)}</h2><p>${esc(item.inventory_number)} · ${esc(item.recipient)}</p>
        <p>Ще у виданому залишку — ${esc(item.outstanding)} ${esc(item.unit)}</p>
        <p>${item.confirmed_at ? 'Отримання підтверджено' : 'Очікується підтвердження отримувача'}</p>`;
      if (item.can_confirm && !seen.has(item.issue_id)) {
        const confirmReceipt = document.createElement('button');
        confirmReceipt.className = 'primary full';
        confirmReceipt.textContent = 'Підтвердити отримання видачі';
        confirmReceipt.onclick = () => form('Підтвердження отримання',
          '<p>Підтверджую отримання всіх позицій цієї видачі.</p>',
          () => stockAction('stage_stock_confirm', { p_issue: item.issue_id }, 'Отримання підтверджено'));
        card.append(confirmReceipt);
        seen.add(item.issue_id);
      }
      if (item.can_return) {
        const returnItem = document.createElement('button');
        returnItem.className = 'full';
        returnItem.textContent = 'Зафіксувати повернення';
        returnItem.onclick = () => stockReturnForm(item);
        card.append(returnItem);
      }
      list.append(card);
    }
    if (!data.approved.length && !data.outstanding.length) {
      list.insertAdjacentHTML('beforeend', '<p>Немає видач або повернень, які потребують дії.</p>');
    }
  } catch (error) {
    if (list.isConnected) list.textContent = 'Не вдалося завантажити операції.';
    fail(error);
  }
}

async function stockAction(rpc, args, message) {
  try {
    await take(db.rpc(rpc, args));
    if (rpc !== 'stage_stock_confirm') await loadLive();
    toast(message);
    return true;
  } catch (error) {
    fail(error);
    return false;
  }
}

function stockIssueForm(reservation) {
  const items = reservation.items || [];
  form('Фізична видача', `
    <p>Звірте стан і комплектність з останніми фото. Введіть QR кожної позиції камерою або з етикетки.</p>
    ${items.map(item => `<label>${esc(item.name)} · ${esc(item.number)}
      <input name="qr" autocomplete="off" required></label>`).join('')}
    <label><input type="checkbox" required style="width:auto"> Стан і комплектність звірено</label>`,
    data => stockAction('stage_stock_issue', {
      p_reservation: reservation.id,
      p_scanned: Object.fromEntries(data.getAll('qr').map((code, position) => [items[position].id, code.trim()]))
    }, 'Фізичну видачу зафіксовано'));
  enableStockCamera();
}

function stockReturnForm(item) {
  const consumable = item.tracking_type === 'consumable';
  const key = crypto.randomUUID();
  form('Фізичне приймання', `
    <p>${esc(item.name)} · залишок ${esc(item.outstanding)} ${esc(item.unit)}</p>
    <label>Склад приймання<select name="warehouse" required>${optionIds('warehouses')}</select></label>
    ${consumable ? `<label>Повернуто<input name="returned" type="number" min="0" step="any" value="0" required></label>
      <label>Використано<input name="consumed" type="number" min="0" step="any" value="0" required></label>` : ''}
    <label><input type="checkbox" required style="width:auto"> Фізичне приймання або використання підтверджено</label>`,
    data => stockAction('stage_stock_return', {
      p_item: item.item_id, p_warehouse: data.get('warehouse'), p_key: key,
      p_returned: consumable ? data.get('returned') : 1, p_consumed: consumable ? data.get('consumed') : 0
    }, 'Приймання або використання збережено'));
}

function stockTransferForm() {
  const items = records.filter(item => item.location_type === 'warehouse');
  const key = crypto.randomUUID();
  form('Підтвердити переміщення між складами', `
    <label>Майно<select name="asset" required><option value="">Оберіть майно</option>
      ${items.map(item => `<option value="${safeId(item.id)}">${esc(item.name)} · ${esc(item.inventory_number)}</option>`).join('')}
    </select></label>
    <label>Склад призначення<select name="warehouse" required>${optionIds('warehouses')}</select></label>
    ${field('qr', 'QR із етикетки')}
    <label><input type="checkbox" required style="width:auto"> Майно фізично прийнято на складі призначення</label>`,
    data => stockAction('stage_stock_transfer', {
      p_asset: data.get('asset'), p_warehouse: data.get('warehouse'), p_scanned: data.get('qr').trim(), p_key: key
    }, 'Місцеперебування оновлено'));
  enableStockCamera();
}

function enableStockCamera() {
  const video = document.createElement('video');
  video.playsInline = true;
  video.muted = true;
  video.hidden = true;
  video.style.cssText = 'width:100%;max-height:36vh';
  const status = document.createElement('p');
  status.setAttribute('role', 'status');
  const controls = document.createElement('div');
  controls.append(video, status);
  modal.querySelector('form').prepend(controls);

  for (const input of modal.querySelectorAll('[name=qr]')) {
    const button = document.createElement('button');
    button.type = 'button';
    button.textContent = 'Увімкнути камеру';
    button.onclick = () => {
      const stopping = cameraSession?.toggle === button;
      stopCamera();
      if (stopping) return;
      input.closest('label').after(controls);
      scanCamera(video, button, status, value => { input.value = value; });
    };
    input.closest('label').after(button);
  }
  modal.addEventListener('close', stopCamera, { once: true });
}
