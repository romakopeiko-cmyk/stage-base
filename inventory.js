'use strict';

const inventoryStatus = {
  pending:'Очікує обліку', verified:'Звірено', missing:'Відсутнє', surplus:'Надлишок',
  quantity_mismatch:'Розбіжність кількості', in_progress:'Триває', completed:'Завершено',
  draft:'Чернетка', cancelled:'Скасовано'
};

async function renderWarehouseInventory(session = null) {
  app.innerHTML = '<h1>Інвентаризація складу</h1><div id="inventory-content" aria-live="polite">Завантаження…</div>';
  const target = app.querySelector('#inventory-content');
  const button = (label, action, primary = false) => {
    const element = document.createElement('button');
    element.className = primary ? 'primary full' : 'full';
    element.textContent = label;
    element.onclick = action;
    return element;
  };
  try {
    const data = await take(db.rpc('stage_warehouse_inventory', {p_session:session}));
    if (!target.isConnected) return;
    target.replaceChildren();
    if (!session && data.can_create) target.append(button('Почати облік', () => {
      form('Новий облік доступного майна', field('name', 'Назва обліку') +
        `<label>Склад<select name="warehouse" required>${optionIds('warehouses')}</select></label>`,
        async fields => {
          try {
            const id = await take(db.rpc('stage_start_warehouse_inventory', {
              p_name:fields.get('name').trim(), p_warehouse:fields.get('warehouse')
            }));
            renderWarehouseInventory(id);
            return true;
          } catch (error) { fail(error); return false; }
        });
    }, true));

    if (session) target.append(button('Усі обліки', () => renderWarehouseInventory()));
    if (!data.sessions.length) target.insertAdjacentHTML('beforeend','<p>Немає доступних обліків.</p>');
    for (const entry of data.sessions) {
      const card = document.createElement('article');
      card.className = 'card line';
      card.innerHTML = `<h2>${esc(entry.name)}</h2><p>${esc(entry.warehouse)} · ${esc(inventoryStatus[entry.status] ?? entry.status)}</p>`;
      if (!session) card.append(button('Відкрити облік', () => renderWarehouseInventory(entry.id)));
      target.append(card);
    }

    const open = data.sessions[0]?.status === 'in_progress';
    for (const item of data.items) {
      const card = document.createElement('article');
      card.className = 'card line';
      card.innerHTML = `<h2>${esc(item.name)}</h2><p>${esc(item.number)} · ${esc(inventoryStatus[item.status] ?? item.status)}</p>
        <p>Очікується ${esc(item.expected)} · Фактично ${esc(item.actual ?? '—')}</p>`;
      if (open && data.can_count) card.append(button('Зафіксувати кількість', () => {
        form('Звірка кількості', '<label>Фактична кількість<input name="actual" type="number" min="0" step="0.001" required></label>' +
          '<label>QR із етикетки<input name="qr" autocomplete="off"></label><p>Для відсутньої позиції введіть 0.</p>',
          async fields => {
            const saved = await inventoryAction('stage_record_warehouse_count', {
              p_session:session, p_item:item.id, p_qr:fields.get('qr').trim(), p_actual:Number(fields.get('actual'))
            });
            if (saved) renderWarehouseInventory(session);
            return saved;
          });
        enableStockCamera();
      }));
      target.append(card);
    }

    if (session && open && data.can_complete && data.items.length && data.items.every(item => item.status !== 'pending')) {
      target.append(button('Завершити облік', () => form('Завершення обліку',
        '<p>Підтвердіть завершення фізичної звірки.</p>', async () => {
          const saved = await inventoryAction('stage_complete_warehouse_inventory', {p_session:session});
          if (saved) renderWarehouseInventory(session);
          return saved;
        }), true));
    }
  } catch (error) {
    if (target.isConnected) target.textContent = 'Не вдалося завантажити інвентаризацію.';
    fail(error);
  }
}

async function inventoryAction(rpc, payload) {
  try {
    await take(db.rpc(rpc, payload));
    toast('Облік збережено');
    return true;
  } catch (error) {
    fail(error);
    return false;
  }
}
