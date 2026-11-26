'use strict';

const catalogConditions = {
  unassessed: 'Не перевірено', serviceable: 'Справне', repair_needed: 'Потребує ремонту', irreparable: 'Не підлягає ремонту'
};

async function renderStageCatalog(container) {
  const [rights, assets] = await Promise.all([
    take(db.rpc('stage_catalog_capabilities')),
    take(db.from('assets').select('id,name,inventory_number,category,color,material,notes,condition,quantity,unit')
      .eq('archived',false).order('name').limit(100))
  ]);
  if (!container.isConnected) return;
  container.replaceChildren();
  const control = (label, handler) => {
    const button = document.createElement('button');
    button.textContent = label;
    button.className = 'full';
    button.onclick = handler;
    return button;
  };
  if (rights.create) {
    const create = control('Додати майно', () => stageAssetForm().catch(fail));
    create.classList.add('primary');
    container.append(create);
  }
  if (!assets.length) container.append('Майна поки немає.');
  for (const item of assets) {
    const card = document.createElement('article');
    card.className = 'card';
    card.innerHTML = '<h3>' + esc(item.name) + '</h3><p>' + esc(item.inventory_number) + ' · ' +
      esc(item.quantity) + ' ' + esc(item.unit) + '</p><small>' + esc(catalogConditions[item.condition] || item.condition) + '</small>';
    card.append(control('Картка та історія', () => stageAssetDetail(item).catch(fail)));
    if (rights.edit) card.append(control('Редагувати', () => stageAssetForm(item).catch(fail)));
    container.append(card);
  }
}

async function stageAssetDetail(item) {
  const [events, qr] = await Promise.all([
    take(db.from('asset_events').select('event_type,created_at').eq('asset_id', item.id).order('created_at',{ascending:false}).limit(30)),
    loadQrLibrary('qrcode','https://cdn.jsdelivr.net/npm/qrcode-generator@1.4.4/qrcode.js',
      'sha384-8FWZA6BGMXhsfO+BLtrJK0We6gg5o1JyO8xQm6peWDEUs17ACA5ziE/NIAkl9z2k').catch(() => null)
  ]);
  if (page !== 'catalog') return;
  modal.innerHTML = '<h2>' + esc(item.name) + '</h2><p>' + esc(item.inventory_number) + '</p>' +
    '<p>' + esc([item.category,item.color,item.material].filter(Boolean).join(' · ')) + '</p><p>' + esc(item.notes) +
    '</p><div id="catalog-qr"></div><h3>Історія</h3>' + (events.map(event =>
      '<p>' + esc(({ 'catalog.created':'Картку створено','catalog.updated':'Картку оновлено' })[event.event_type] || 'Складська дія') +
      ' · ' + esc(new Date(event.created_at).toLocaleString('uk-UA')) + '</p>').join('') || '<p>Записів поки немає.</p>') +
    '<button type="button" class="full">Закрити</button>';
  modal.querySelector('button').onclick = () => modal.close();
  if (qr) {
    const code = qr(0,'M');
    code.addData(item.inventory_number,'Byte');
    code.make();
    modal.querySelector('#catalog-qr').innerHTML = code.createSvgTag({cellSize:4,margin:16});
  }
  modal.showModal();
}

async function stageAssetForm(item) {
  let locations = '';
  if (!item) {
    const [shows, warehouses] = await Promise.all([
      take(db.from('shows').select('id,name').order('name')),
      take(db.from('warehouses').select('id,name').order('name'))
    ]);
    if (page !== 'catalog') return;
    const options = rows => rows.map(row => '<option value="' + esc(row.id) + '">' + esc(row.name) + '</option>').join('');
    locations = '<label>Склад<select name="warehouse" required><option value="">Оберіть склад</option>' + options(warehouses) +
      '</select></label><label>Шоу<select name="show"><option value="">Без прив’язки</option>' + options(shows) +
      '</select></label><label>Тип обліку<select name="tracking"><option value="individual">Окремий предмет</option>' +
      '<option value="set">Комплект</option><option value="consumable">Витратний матеріал</option></select></label>' +
      '<label>Кількість<input name="quantity" type="number" step="any" min="0.001" value="1" required></label>' +
      '<label>Одиниця виміру<input name="unit" maxlength="24" value="шт." required></label>';
  }
  form(item ? 'Редагувати майно' : 'Додати майно',
    '<label>Назва<input name="name" value="' + esc(item?.name) + '" maxlength="180" required></label>' +
    '<label>Категорія<input name="category" value="' + esc(item?.category) + '" maxlength="120"></label>' +
    '<label>Колір<input name="color" value="' + esc(item?.color) + '" maxlength="80"></label>' +
    '<label>Матеріал<input name="material" value="' + esc(item?.material) + '" maxlength="120"></label>' +
    '<label>Примітки<textarea name="notes" maxlength="4000">' + esc(item?.notes) + '</textarea></label>' + locations,
    async data => {
      await take(db.rpc('stage_catalog_save', {
        p_asset:item?.id ?? null,p_name:data.get('name'),p_category:data.get('category'),
        p_color:data.get('color'),p_material:data.get('material'),p_notes:data.get('notes'),
        ...(!item ? {p_show:data.get('show') || null,p_warehouse:data.get('warehouse'),
          p_tracking:data.get('tracking'),p_quantity:Number(data.get('quantity')),p_unit:data.get('unit')} : {})
      }));
      toast('Картку збережено');
      modal.close();
      if (page === 'catalog') await renderStageSection('catalog');
      return false;
    });
}
