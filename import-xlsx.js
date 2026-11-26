'use strict';

const workbookFields = [
  'Джерело', 'Назва', 'Інвентарний номер', 'Первинний номер', 'Категорія',
  'Тип обліку', 'Кількість', 'Одиниця', 'Первісна вартість', 'Склад', 'Опис',
  'Коментар', 'Посилання на фото', 'Стан', 'Потребує рішення'
];
const originalFields = [
  'Джерело', 'Вид', 'Назва', 'Інвентарний номер', 'Кількість', 'Первісна вартість',
  'Фото', 'Склад', 'Опис', 'Коментар'
];
const typeFromWorkbook = new Map([
  ['Окремий предмет', 'individual'],
  ['Комплект', 'set'],
  ['Витратний матеріал', 'consumable']
]);

function workbookRows(xlsx, workbook, name, fields) {
  if (!Object.hasOwn(workbook.Sheets, name)) throw Error('У книзі немає аркуша «' + name + '»');
  const sheet = workbook.Sheets[name];
  const range = xlsx.utils.decode_range(sheet['!ref'] || 'A1');
  if (range.e.r > 2000 || range.e.c > 31) throw Error('Аркуш виходить за межі шаблону імпорту');
  const rows = xlsx.utils.sheet_to_json(sheet, { header: 1, defval: '', blankrows: false, raw: false });
  if (fields && !fields.every((key, index) => rows[0]?.[index] === key)) {
    throw Error('Перевірте заголовки аркуша «' + name + '»');
  }
  // Import accepts literal values. A formula may have a stale cached result.
  if (Object.values(sheet).some(cell => cell && typeof cell === 'object' && cell.f)) {
    throw Error('Замініть формули на перевірені значення в аркуші «' + name + '»');
  }
  return rows.slice(1);
}

function workbookSource(label) {
  const pdf = /^Стор\.\s*(\d+)\s*\/\s*(\d+)\s*\/\s*(\d+)$/.exec(label);
  if (pdf) return 'pdf:' + pdf.slice(1).join(':');
  const sheet = /^(.+)\s\/\s(\d+)$/.exec(label);
  if (sheet) return 'xlsx:' + sheet[1] + ':' + sheet[2];
  throw Error('Не розпізнано вихідний рядок ' + label);
}

function catalogWorkbookPackage(xlsx, workbook) {
  const rows = workbookRows(xlsx, workbook, 'Каталог', workbookFields);
  const source = workbookRows(xlsx, workbook, 'Первинні дані', originalFields);
  const summary = workbookRows(xlsx, workbook, 'Підсумок', ['Показник', 'Значення']);
  const digest = summary.find(row => row[0] === 'Джерело SHA-256')?.[1];
  if (!/^[0-9a-f]{64}$/.test(digest || '')) throw Error('У підсумку відсутній SHA-256 джерела');
  const originals = new Map(source.map(row => [row[0], row]));
  if (originals.size !== source.length || source.length !== rows.length) {
    throw Error('Первинні дані не збігаються з рядками каталогу');
  }
  const items = [];
  const excluded = [];
  const numbers = new Set();
  for (const row of rows) {
    const [label, name, number, originalNumber, category, type, quantity, unit, , warehouse,
      description, comment, links, , review] = row;
    const original = originals.get(label);
    if (!original) throw Error('Не знайдено первинні дані для ' + label);
    originals.delete(label);
    const sourceRow = workbookSource(label);
    if ((original[3] || '') !== (originalNumber || '') || (originalNumber && number !== originalNumber)) {
      throw Error('Первинний номер відрізняється у рядку ' + label);
    }
    if (!number || !name) {
      if (originalNumber) throw Error('Позиція з первинним номером неповна: ' + label);
      excluded.push(sourceRow);
      continue;
    }
    const normalized = number.trim().toLowerCase();
    if (!normalized || numbers.has(normalized)) throw Error('Некоректний або повторний номер: ' + label);
    numbers.add(normalized);
    if (type && !typeFromWorkbook.has(type)) throw Error('Невідомий тип обліку у рядку ' + label);
    items.push({
      source_row: sourceRow, inventory_number: number, original_number: originalNumber || null,
      name, category, tracking_type: typeFromWorkbook.get(type) || null, quantity: quantity || null,
      unit, warehouse_hint: warehouse, description, comment,
      review: (review || '').split(/\r?\n/).filter(Boolean),
      photo_links: (links || '').split(/\r?\n/).filter(Boolean),
      original: {
        kind: original[1], name: original[2], inventory_number: original[3] || null,
        quantity: original[4], initial_value: original[5], photo: original[6], warehouse: original[7],
        description: original[8], comment: original[9]
      }
    });
  }
  return { source_sha256: digest, items, excluded };
}

function validateWorkbookZip(buffer) {
  const bytes = new DataView(buffer);
  let end = bytes.byteLength - 22;
  const floor = Math.max(0, end - 65535);
  while (end >= floor && (bytes.getUint32(end, true) !== 0x06054b50 ||
      end + 22 + bytes.getUint16(end + 20, true) !== bytes.byteLength)) end--;
  if (end < floor) throw Error('Некоректний контейнер Excel');
  const count = bytes.getUint16(end + 10, true);
  let cursor = bytes.getUint32(end + 16, true);
  const directoryEnd = cursor + bytes.getUint32(end + 12, true);
  if (count < 1 || count > 100 || directoryEnd !== end ||
      bytes.getUint16(end + 4, true) || bytes.getUint16(end + 6, true)) {
    throw Error('Контейнер Excel виходить за межі шаблону');
  }
  let expanded = 0;
  for (let index = 0; index < count; index++) {
    if (cursor + 46 > end || bytes.getUint32(cursor, true) !== 0x02014b50) {
      throw Error('Некоректний каталог Excel');
    }
    expanded += bytes.getUint32(cursor + 24, true);
    if (expanded > 32 * 1024 * 1024 || (bytes.getUint16(cursor + 8, true) & 1)) {
      throw Error('Надто велика або зашифрована книга Excel');
    }
    cursor += 46 + bytes.getUint16(cursor + 28, true) + bytes.getUint16(cursor + 30, true)
      + bytes.getUint16(cursor + 32, true);
  }
  if (cursor !== directoryEnd) throw Error('Некоректний розмір каталогу Excel');
}

async function parseImportWorkbook(file) {
  const buffer = await file.arrayBuffer();
  validateWorkbookZip(buffer);
  const library = await loadQrLibrary('XLSX',
    'https://cdn.sheetjs.com/xlsx-0.20.3/package/dist/xlsx.full.min.js',
    'sha384-EnyY0/GSHQGSxSgMwaIPzSESbqoOLSexfnSMN2AP+39Ckmn92stwABZynq1JyzdT');
  const workbook = library.read(buffer, {
    type: 'array', sheetRows: 2002, sheets: ['Каталог', 'Первинні дані', 'Підсумок']
  });
  return catalogWorkbookPackage(library, workbook);
}
