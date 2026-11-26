"""Create a private, reviewable Stage Base workbook from extracted inventory."""
import argparse
from collections import Counter
from decimal import Decimal
import json
from pathlib import Path
import re

from openpyxl import Workbook
from openpyxl.styles import Alignment, Font, PatternFill

from photo_status import check_links
from preview import normalized

# Apply to standalone words and phrases so product models and identifiers survive.
TERMS = {
    "светодиодное освещение": "світлодіодне освітлення",
    "оградітельние столбики очереди": "стійки огорожі для черги",
    "аерограф аэрограф": "аерограф", "оградітельние": "огороджувальні",
    "столбики": "стійки", "очереди": "черги", "освещение": "освітлення",
    "светодиодное": "світлодіодне", "герлянда": "гірлянда", "гирлянда": "гірлянда",
    "аэрограф": "аерограф", "с компрессором": "з компресором", "компрессором": "компресором",
    "ветилятор": "вентилятор", "вытяжка": "витяжка", "стол": "стіл",
    "монитор": "монітор", "компьютор": "комп’ютер", "компьютер": "комп’ютер",
    "памяти": "пам’яті", "павельон": "павільйон", "павильон": "павільйон",
    "пистолет": "пістолет", "этажерка": "етажерка", "ремонта": "ремонту",
    "документов": "документів", "брюки": "штани", "стакан": "склянка",
    "груза": "вантажі", "груз": "вантаж", "топор": "сокира",
    "медальони": "медальйони", "перчатки": "рукавички", "плашетів": "планшетів",
    "шурок": "шнурок", "бейджу": "бейджа", "ящика": "ящика",
    "штаны": "штани", "эльфийские": "ельфійські", "эльфийская": "ельфійська",
    "эльф": "ельф", "юбка": "спідниця", "шлем": "шолом",
    "шкаф": "шафа", "без тормоза": "без гальма", "тормоза": "гальма",
    "серо": "сіро", "черн": "чорн", "кассовый": "касовий", "вентилятор": "вентилятор",
    "фильм.юа": "FILM.UA", "фільм.юа": "FILM.UA", "вднх": "ВДНГ",
    "размер": "розмір", "размеры": "розміри", "оборудование": "обладнання",
    "деревянный": "дерев’яний", "металлический": "металевий", "черный": "чорний",
    "белый": "білий", "красный": "червоний", "синий": "синій", "зеленый": "зелений",
    "цвет": "колір", "прибор": "прилад", "запчасти": "запчастини",
    "подставка": "підставка", "тележка": "візок", "каркас": "каркас",
    "лестница": "драбина", "крепление": "кріплення", "провод": "провід",
    "удлинитель": "подовжувач", "светильник": "світильник", "зажим": "затискач",
    "комплектующие": "комплектувальні", "переходник": "перехідник",
    "кронштейн": "кронштейн", "зарядное устройство": "зарядний пристрій",
    "аккумулятор": "акумулятор", "мышь": "миша", "жесткий диск": "жорсткий диск",
    "шкафчик": "шафка", "сумка": "сумка", "наклейки": "наліпки",
    "полотенце": "рушник", "кровать": "ліжко", "подушка": "подушка",
    "пуговицы": "ґудзики", "рубашка": "сорочка", "платье": "сукня",
    "чехол": "чохол", "зеркало": "дзеркало", "поднос": "таця",
    "подключение": "підключення", "внешний": "зовнішній", "внутренний": "внутрішній",
    "количество": "кількість", "комментарий": "коментар", "потребує ремонта": "потребує ремонту",
    "бульбашк машина": "машина для мильних бульбашок", "дим машина": "димова машина",
    "холоднобілого": "холодного білого", "ведро": "відро", "огнетушитель": "вогнегасник",
    "набор": "набір", "коробка": "коробка", "панели": "панелі",
    "настольный": "настільний", "напольный": "підлоговий", "сценический": "сценічний",
}
TERMS.update({
    "звукоизоляция и утепление": "звукоізоляція й утеплення", "зрительный зал": "глядацька зала",
    "компютер": "комп’ютер", "конструктив сцены": "конструкція сцени",
    "ремонтные работы": "ремонтні роботи", "гримерки": "гримерні", "бары": "бари", "туалеты": "вбиральні",
    "клавиатура": "клавіатура", "мишка": "миша", "сушильная машина": "сушильна машина",
    "для кулис": "для лаштунків", "сушилка": "сушарка", "багатофункціональный": "багатофункціональний",
    "електролобзік": "електролобзик", "ледогенератор": "льодогенератор", "ибп": "ДБЖ",
    "петличный микрофон": "петличний мікрофон", "полка навесная": "навісна полиця",
    "гидравлічні": "гідравлічні", "узел учета электроэнергии": "вузол обліку електроенергії",
    "большая книга": "велика книга", "с вилкой и розеткой": "з вилкою та розеткою",
    "глицінія": "гліцинія", "диммашина": "димова машина", "карандаши": "олівці",
    "для упаковки направляючих": "для пакування напрямних", "лосины": "лосини",
    "медальйон светящийся": "світний медальйон", "медальйони светящийся": "світні медальйони",
    "накладки на обувь": "накладки на взуття", "красные": "червоні", "обувь кеды": "взуття — кеди",
    "подарочные коробки": "подарункові коробки", "сундук": "скриня", "шапка с ушами": "шапка з вухами",
    "стакан паперовий": "паперова склянка", "стакан поліпропіленовий": "поліпропіленова склянка",
    "трибуны из падестов": "трибуни з подіумів", "телефонный аппарат": "телефонний апарат",
    "фотозоны": "фотозони", "волшебницы": "Чарівниці", "боди": "боді", "санты": "Санти",
    "галстук": "краватка", "часовщика": "Годинникаря", "удлиненный пиджак": "подовжений піджак",
    "эльфа": "ельфа", "деревяна": "дерев’яна", "проектор": "проєктор",
})
WORDS = re.compile(r"(?<!\w)(?:" + "|".join(map(re.escape, sorted(TERMS, key=len, reverse=True))) + r")(?!\w)", re.I)
RESIDUAL = re.compile(r"\b[а-яіїєґ]*[ыэъё][а-яіїєґ]*\b", re.I)
CATEGORIES = [
    ("Аудіо- та відеообладнання", r"акустич|діджей|про[еє]ктор|відеокамер|відеореєстратор|мікрофон|навушник"),
    ("Електроживлення", r"генератор|інвертор|ДБЖ|безперебій|електроживл|електроенерг|вимикач|розетк|колодка клем|перемикач навантаж|електрична вилка"),
    ("Опалення й вентиляція", r"котел|опален|теплозавіс|теплолічильник|вентилятор|витяжка|зволожувач"),
    ("Офіс та канцелярія", r"печатк|штамп|шредер|олівц|кульк|ручка масл|конверт|файл глянц|флаєр|бейдж|скоби"),
    ("ІТ та зв’язок", r"^ПК\b|сист\. блок|накопичувач|комутатор|МФУ|сканер|роутер"),
    ("Пожежна безпека", r"вогнегас|водопінн|пожежн"),
    ("Костюми й аксесуари", r"костюм|сукн|спідниц|штани|рукавич|сороч|перук|маск|шолом|чоб|черев|капелюх|плащ|пояс|куртк|лосин|кед|футбол|реглан|шапк|жилет|головний убір|взуття"),
    ("Освітлення", r"прожектор|освітлен|гірлянд|ліхтар|світил|люстр|ламп|світлодіод|маяк"),
    ("ІТ та зв’язок", r"ноутбук|принтер|комп[’']ютер|монітор|маршрутиз|модем|раці|телефон|планшет(?!ів)|диск|пам[’']ят|клавіат|блок живлен|миша|сервер"),
    ("Касове обладнання", r"банкнот|валют|касов|касир|грошов|сейф"),
    ("Меблі та зберігання", r"стіле|стільц|стіл|столик|шаф|стелаж|лавк|банкет|кріс|диван|комод|тумб|полиц|меблі|ліжк|етажерк|вішал|скрин|вітрин|контейнер"),
    ("Побутове обладнання", r"пилосос|праль|швей|бойлер|мікрохвиль|чайник|сушар|кондиціонер|тепловентил|конвектор|обігрів|рушник|швабр|відр|посуд|холодильник|кавомашин|льодогенератор|прасувальн|склянк|чашк"),
    ("Конструкції й огорожі", r"конструкц|огорож|перил|розсувн|стійк|павільйон|сход|панел|підставк|планшетів|каркас|трибун|настил|лаштун|ферма|подіум|завіс|сітки"),
    ("Декорації та сценічний реквізит", r"декор|реквізит|фотозон|банер|ялин|ялина|лого|ловець|сан[ии]|потяг|будиноч|камі|муляж|голов[аи]|ляльк|бульбаш|посох|бутафор|Гном|медальйон|подарунк|плакат|зірка|замок Санти|вказівник"),
    ("Інструменти та комплектувальні", r"аерограф|сокира|інструмент|дриль|шуруп|кабель|колес|кріплен|кронштейн|подовжувач|патрон|затискач|перехідник|лобзик|пил[аи]|компресор|прес-кліщ|термоповітр|фарбопульт|рулетк|драбин|візок|відбійник"),
    ("Витратні матеріали", r"барвник|батарейк|стрічка|рідина|клей|папір|серветк|пакет|фарба|скотч"),
]
CONSUMABLE = re.compile(r"^(?:[- ]*)(?:барвник|батарейк\w*|рідина|клей|папір|серветк\w*|фарба|скотч|ізолента|білизна|засіб для прочищення|скоби|чиста вода|наліпка)\b", re.I)
SET = re.compile(r"\b(?:комплект|набір)\s+|\bв компл(?:екті)?\b", re.I)


def ukrainian(text):
    def replace(match):
        word = match[0]
        replacement = TERMS[word.casefold()]
        if word.isupper():
            return replacement.upper()
        return replacement[:1].upper() + replacement[1:] if word[:1].isupper() else replacement
    return WORDS.sub(replace, text or "")


def propose(source, occupied, counters):
    original = source["inventory_number"]
    if original:
        return original
    while True:
        counters["sequence"] += 1
        code = f'SB-IMP-{counters["sequence"]:06}'
        if normalized(code) not in occupied:
            occupied.add(normalized(code))
            return code


def prepare(data, existing):
    rows = data["rows"]
    occupied = {normalized(x) for x in existing} | {normalized(r["inventory_number"]) for r in rows}
    existing = {normalized(x) for x in existing}
    counters = Counter()
    for r in rows:
        name, details, comment = (ukrainian(r[field]) for field in ("name", "description", "comment"))
        check = []
        heading = bool(name.endswith(":") and not name.startswith("-") and not any(
            (r["inventory_number"], r["quantity_decimal"], r["initial_value"], r["description"], r["photo_links"])
        ))
        quantity_text = r["quantity_decimal"]
        unit = r["unit"] or ""
        if not quantity_text and r["quantity"]:
            m = re.fullmatch(r"\s*(\d+(?:[,.]\d+)?)\s*(шт\.?|л|м|кг|пог\.?\s*м)\s*", r["quantity"], re.I)
            if m:
                quantity_text, unit = m[1].replace(",", "."), m[2]
        quantity = Decimal(quantity_text) if quantity_text is not None else None
        if CONSUMABLE.search(name) or normalized(unit) in {"л", "кг", "пог. м", "пог м"}:
            tracking = "Витратний матеріал"
        elif SET.search(name) and quantity == 1:
            tracking = "Комплект"
        elif quantity == 1 and not SET.search(name):
            tracking = "Окремий предмет"
        else:
            tracking = ""
        category = next((label for label, pattern in CATEGORIES if re.search(pattern, name, re.I)), "")
        if tracking == "Витратний матеріал":
            category = "Витратні матеріали"
        warehouse = ukrainian(r["warehouse"])
        if warehouse not in {"ВДНГ", "FILM.UA", ""}:
            check.append("У полі складу є текст, що потребує звірки")
            warehouse = ""
        if heading:
            check.append("Можливий заголовок групи або комплекту")
        if re.search(r"^(?:ремонтні роботи|звукоізоляція й утеплення)\b", name, re.I):
            check.append("Звірити, чи це фізичне майно, чи обліковий запис робіт")
        if quantity is None or quantity <= 0:
            check.append("Уточнити вихідну кількість")
        elif not tracking:
            check.append("Визначити тип обліку й одиниці для групової позиції")
        if not name:
            check.append("Відновити назву з джерела")
        if not category:
            check.append("Уточнити категорію")
        if RESIDUAL.search(re.sub(r"\b(?:ЭВО|РЭВ)\b", "", " ".join((name, details, comment)), flags=re.I)):
            check.append("Звірити термін або написання в перекладі")
        if r["duplicate_candidates"]:
            check.append("Звірити можливий дубль")
        if normalized(r["inventory_number"]) in existing:
            check.append("Первинний номер уже є в каталозі Stage Base")
        if r["initial_value"] and r["initial_value_decimal"] is None:
            check.append("Звірити вихідну вартість")
        yield r, {
            "name": name, "details": details, "comment": comment, "warehouse": warehouse,
            "quantity": quantity_text, "unit": unit, "category": category, "tracking": tracking,
            "number": propose(r, occupied, counters) if not heading else "", "review": check,
        }


def add_row(sheet, values):
    sheet.append(values)
    # Keep text literal even for spreadsheet formula-like source values.
    for cell in sheet[sheet.max_row]:
        if isinstance(cell.value, str):
            cell.data_type = "s"


def format_sheet(sheet, widths):
    sheet.freeze_panes = "A2"
    sheet.auto_filter.ref = sheet.dimensions
    for i, width in enumerate(widths, 1):
        sheet.column_dimensions[sheet.cell(1, i).column_letter].width = width
    for cell in sheet[1]:
        cell.fill = PatternFill("solid", fgColor="30204F")
        cell.font = Font(color="FFFFFF", bold=True)
        cell.alignment = Alignment(wrap_text=True, vertical="top")


def build(data, existing, statuses, output):
    workbook = Workbook()
    summary = workbook.active
    summary.title = "Підсумок"
    catalog = workbook.create_sheet("Каталог")
    review = workbook.create_sheet("Ручне погодження")
    photos = workbook.create_sheet("Фотопосилання")
    originals = workbook.create_sheet("Первинні дані")
    fields = ["Джерело", "Назва", "Інвентарний номер", "Первинний номер", "Категорія", "Тип обліку",
              "Кількість", "Одиниця", "Первісна вартість", "Склад", "Опис", "Коментар",
              "Посилання на фото", "Стан", "Потребує рішення"]
    for sheet in (catalog, review):
        add_row(sheet, fields)
    add_row(photos, ["Посилання", "Результат перевірки без входу", "Рядки джерела"])
    add_row(originals, ["Джерело", "Вид", "Назва", "Інвентарний номер", "Кількість", "Первісна вартість",
                        "Фото", "Склад", "Опис", "Коментар"])
    link_rows = {}
    counts = Counter()
    for source, row in prepare(data, existing):
        ref = source["source"]
        label = f"Стор. {ref['page']} / {ref['section']} / {ref['row']}" if "page" in ref else f"{ref['sheet']} / {ref['row']}"
        counts["Рядків джерела"] += 1
        counts["Рядків на ручне погодження"] += bool(row["review"])
        counts["Запропонованих номерів"] += bool(row["number"] and not source["inventory_number"])
        counts["Первинних номерів"] += bool(source["inventory_number"])
        counts["Без зазначеного складу"] += not bool(row["warehouse"])
        counts[row["tracking"] or "Тип обліку не визначено"] += 1
        values = [label, row["name"], row["number"], source["inventory_number"], row["category"], row["tracking"],
                  Decimal(row["quantity"]) if row["quantity"] else None, row["unit"],
                  Decimal(source["initial_value_decimal"]) if source["initial_value_decimal"] else None,
                  row["warehouse"], row["details"], row["comment"], "\n".join(source["photo_links"]),
                  "Не перевірено", "\n".join(row["review"])]
        add_row(catalog, values)
        if row["review"]:
            add_row(review, values)
        add_row(originals, [label, *(source[key] for key in (
            "kind", "name", "inventory_number", "quantity", "initial_value", "photo",
            "warehouse", "description", "comment"
        ))])
        for link in source["photo_links"]:
            link_rows.setdefault(link, []).append(label)
    for link, labels in sorted(link_rows.items()):
        add_row(photos, [link, statuses.get(link, "Не перевірено"), "\n".join(labels)])
    add_row(summary, ["Показник", "Значення"])
    for key, value in counts.items():
        add_row(summary, [key, value])
    for result, count in Counter(statuses.get(link, "Не перевірено") for link in link_rows).items():
        add_row(summary, [result, count])
    add_row(summary, ["Джерело SHA-256", data["sha256"]])
    add_row(summary, ["Порожній склад", "Фізичне місцеперебування потрібно уточнити до запису, якщо схема імпорту його вимагає."])
    add_row(summary, ["Первісна вартість", "Оригінальне значення без припущень про валюту або ціну одиниці."])
    add_row(summary, ["Перевірка після імпорту", "Комірник звіряє фактичну наявність, кількість, стан і комплектність."])
    for sheet, widths in [(summary, [50, 105]), (photos, [95, 56, 36]), (originals, [29, 12, 60, 21, 16, 20, 55, 22, 49, 53]),
                          (catalog, [29, 63, 23, 23, 34, 24, 14, 13, 20, 16, 51, 51, 60, 19, 66]),
                          (review, [29, 63, 23, 23, 34, 24, 14, 13, 20, 16, 51, 51, 60, 19, 66])]:
        format_sheet(sheet, widths)
    with output.open("xb") as destination:
        workbook.save(destination)
    print(dict(counts))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("preview", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--existing", type=Path, required=True, help="Локальний JSON-масив номерів чинного каталогу")
    photos = parser.add_mutually_exclusive_group()
    photos.add_argument("--photo-status", type=Path, help="Локальний JSON зі статусами доступу")
    photos.add_argument("--check-photos", action="store_true", help="Анонімно перевірити вихідні посилання")
    args = parser.parse_args()
    data = json.loads(args.preview.read_text())
    existing = json.loads(args.existing.read_text())
    statuses = json.loads(args.photo_status.read_text()) if args.photo_status else {}
    if args.check_photos:
        statuses = check_links(sorted({link for row in data["rows"] for link in row["photo_links"]}))
    build(data, existing, statuses, args.output)


if __name__ == "__main__":
    main()
