'use strict';

const intakeRole = () => ['executive_producer', 'warehouse_manager'].includes(roleCode());
const importTypeLabels = { individual: 'Окремий предмет', set: 'Комплект', consumable: 'Витратний матеріал' };

async function renderImportIntake() {
  app.innerHTML = '<h1>Майно потребує уточнення</h1>';
  if (!intakeRole()) return;
  if (roleCode() === 'executive_producer') {
    const upload = document.createElement('button');
    upload.className = 'primary full';
    upload.textContent = 'Переглянути пакет імпорту';
    upload.onclick = selectImportPackage;
    app.append(upload);
  }

  const list = document.createElement('section');
  app.append(list);
  let cursor = 0;
  async function nextPage() {
    const previous = list.querySelector('#import-next');
    if (previous) previous.disabled = true;
    try {
      const rows = await take(db.rpc('stage_list_import_items', { p_after: cursor }));
      if (!list.isConnected) return;
      previous?.remove();
      if (!cursor && !rows.length) list.textContent = 'Черга уточнення порожня.';
      for (const row of rows) {
        const card = document.createElement('article');
        card.className = 'card line';
        card.innerHTML = `<h2>${esc(row.name)}</h2><p>${esc(row.inventory_number)} · ${esc(row.source_row)}</p>
          <p>За джерелом: ${esc(row.warehouse_hint || 'склад невідомий')} ·
          ${esc(row.quantity_hint || 'кількість невідома')} · ${esc(importTypeLabels[row.tracking_hint] || 'тип невідомий')}</p>`;
        const resolve = document.createElement('button');
        resolve.className = 'full';
        resolve.textContent = 'Уточнити позицію';
        resolve.onclick = () => resolveImportItem(row);
        card.append(resolve);
        list.append(card);
        cursor = row.id;
      }
      if (rows.length === 50) {
        const more = document.createElement('button');
        more.id = 'import-next';
        more.className = 'full';
        more.textContent = 'Показати ще';
        more.onclick = nextPage;
        list.append(more);
      }
    } catch (error) {
      if (previous) previous.disabled = false;
      fail(error);
    }
  }
  await nextPage();
}

function selectImportPackage() {
  const input = document.createElement('input');
  input.type = 'file';
  input.accept = '.xlsx,.json,application/json';
  input.onchange = async () => {
    try {
      const file = input.files[0];
      if (!file || file.size > 4 * 1024 * 1024) throw Error('Оберіть Excel або JSON до 4 МБ');
      const data = /\.xlsx$/i.test(file.name) ? await parseImportWorkbook(file) : JSON.parse(await file.text());
      if (!/^[0-9a-f]{64}$/.test(data.source_sha256) || !Array.isArray(data.items)
          || data.items.length < 1 || data.items.length > 2000) {
        throw Error('Некоректний пакет імпорту');
      }
      if (page !== 'import-intake') return;
      const excluded = Array.isArray(data.excluded) ? data.excluded.length : 0;
      const rows = data.items.map(row => `<li>${esc(row?.inventory_number)} · ${esc(row?.name)}</li>`).join('');
      form('Попередній перегляд імпорту', `
        <p>${data.items.length} позицій у чергу. Поза пакетом для звірки: ${excluded}.</p>
        <details><summary>Показати позиції</summary><ol>${rows}</ol></details>
        <label><input type="checkbox" style="width:auto" required> Підтверджую завантаження до черги уточнення</label>`,
      async () => {
        try {
          await take(db.rpc('stage_import_inventory', { p_source_hash: data.source_sha256, p_items: data.items }));
          toast('Пакет додано до черги уточнення');
          return true;
        } catch (error) {
          fail(error);
          return false;
        }
      });
    } catch (error) {
      fail(error);
    }
  };
  input.click();
}

function resolveImportItem(item) {
  const types = Object.entries(importTypeLabels).map(([value, label]) =>
    `<option value="${value}">${label}</option>`).join('');
  form('Уточнити позицію', `
    <p>${esc(item.name)} · ${esc(item.inventory_number)}</p>
    <label>Підтверджений склад<select name="warehouse" required>${optionIds('warehouses')}</select></label>
    ${item.fromCatalog ? `<p>Шоу за джерелом — ${esc(item.show_hint ?? 'потребує уточнення')}</p>
      <label>Підтверджене шоу<select name="show">${optionIds('shows')}</select></label>` : ''}
    <label>Тип обліку<select name="type" required><option value="">Оберіть тип</option>${types}</select></label>
    <label>Кількість<input name="quantity" type="number" min="0.001" step="any" required></label>
    ${field('unit', 'Одиниця виміру')}`,
  async data => {
    try {
      await take(db.rpc(item.fromCatalog ? 'stage_resolve_catalog_import' : 'stage_resolve_import_item', {
        p_item: item.id, p_warehouse: data.get('warehouse'), p_type: data.get('type'),
        p_quantity: data.get('quantity'), p_unit: data.get('unit'),
        ...(item.fromCatalog ? {p_show:data.get('show') || null} : {})
      }));
      await loadLive();
      toast('Картка готова до фізичної перевірки');
      if (item.fromCatalog) go('catalog');
      return true;
    } catch (error) {
      fail(error);
      return false;
    }
  });
}
