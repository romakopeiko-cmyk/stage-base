"""Prepare an offline inventory review. This tool has no database or network client."""
import argparse
from collections import Counter, defaultdict
from decimal import Decimal, InvalidOperation
from hashlib import sha256
from html import escape
from pathlib import Path
import json
import re
import unicodedata


FIELDS = ("kind", "name", "inventory_number", "quantity", "initial_value", "photo",
          "warehouse", "comment", "description", "unit", "tracking_type")
ALIASES = {
    "вид": "kind", "найменування": "name", "назва": "name",
    "інвентарний №": "inventory_number", "інвентарний номер": "inventory_number",
    "кількість": "quantity", "первісна вартість": "initial_value",
    "фото": "photo", "склад": "warehouse", "коментар": "comment", "опис": "description",
    "одиниця": "unit", "одиниця виміру": "unit", "тип обліку": "tracking_type",
}
URL = re.compile(r"https?://[^\s<>]+", re.IGNORECASE)


def normalized(value):
    return " ".join(unicodedata.normalize("NFC", value or "").casefold().split())


def decimal_text(value):
    cleaned = re.sub(r"\s+", "", value or "").replace(",", ".")
    if not re.fullmatch(r"\d+(?:\.\d+)?", cleaned):
        return None
    try:
        return format(Decimal(cleaned), "f")
    except InvalidOperation:
        return None


def row_record(source, cells, links, raw):
    result = {field: cells.get(field) or None for field in FIELDS}
    number = result["inventory_number"]
    result["inventory_number"] = number.strip() if number and number.strip() not in {"-", "–", "—"} else None
    result["quantity_decimal"] = decimal_text(result["quantity"])
    if not result["quantity"] and result["description"]:
        match = re.fullmatch(r"\s*(\d+(?:[,.]\d+)?)\s*(шт\.?|л|м|кг)\s*", result["description"], re.I)
        if match:
            result["quantity_decimal"] = decimal_text(match[1])
            result["unit"] = result["unit"] or match[2]
    result["initial_value_decimal"] = decimal_text(result["initial_value"])
    # PDF hyperlink annotations take precedence over clipped visible URL text.
    result["photo_links"] = list(dict.fromkeys(links or URL.findall(result["photo"] or "")))
    result["source"] = source
    result["raw"] = raw
    result["proposed_condition"] = "unverified"
    return result


def pdf_rows(path):
    import fitz

    accounting = [(59.7, "kind"), (175.8, "name"), (195.6, "inventory_number"),
                  (209.8, "quantity"), (227, "initial_value"), (239.2, "photo"),
                  (251.4, "warehouse"), (282.2, "comment")]
    supplemental = [(175.2, "name"), (195, "inventory_number"), (209.8, "quantity"),
                    (226.7, "initial_value"), (239.2, "photo"), (251.4, "warehouse"),
                    (282.2, "comment")]
    layouts = [
        (64.94, 8.785, [(134, "name"), (189, "photo"), (337, "description"), (562, "comment")]),
        (70.40, 12.845, [(138.5, "name"), (265.5, "photo"), (394, "description"),
                         (521, "comment"), (562, "extra")]),
        (73.24, 14.352, [(180, "name"), (264, "description"), (562, "comment")]),
        (61.09, 5.692, [(127.5, "name"), (189.5, "photo"), (253.2, "description"),
                        (374.5, "comment"), (562, "warehouse")]),
    ]

    with fitz.open(path) as document:
        if len(document) != 9:
            raise ValueError("Цей профіль PDF очікує дев’ять сторінок експорту Stage Show Company.")
        for page in document:
            page_number = page.number + 1
            spans = [
                (span["bbox"], span["text"])
                for block in page.get_text("dict", flags=fitz.TEXTFLAGS_TEXT)["blocks"]
                for line in block["lines"] for span in line["spans"]
            ]
            expected = "Вид" if page_number <= 5 else "найменування"
            if not any(text.strip() == expected and box[1] < 65 for box, text in spans):
                raise ValueError(f"Сторінка {page_number}: не розпізнано заголовок відомого шаблону.")
            if page_number <= 5:
                specs = [(59.5, 3.6264, accounting, 58.84, 236.6 if page_number == 5 else 738)]
                if page_number == 5:
                    specs.append((239.73, 2.7803, supplemental, 236.6, 421))
            else:
                first, step, columns = layouts[page_number - 6]
                specs = [(first, step, columns, first - 1.5, 792)]

            rows = {}
            def locate(y):
                for section, (first, step, columns, lower, upper) in enumerate(specs):
                    if lower <= y < upper:
                        return (section, round((y - first) / step)), columns
                return None, None

            for box, value in sorted(spans, key=lambda span: (span[0][1], span[0][0])):
                key, columns = locate(box[1])
                if key is None or not value.strip():
                    continue
                row = rows.setdefault(key, {"cells": defaultdict(list), "spans": [], "links": []})
                field = next((name for bound, name in columns if box[0] < bound), "extra")
                row["cells"][field].append(value.strip())
                row["spans"].append({"field": field, "text": value, "bbox": list(box)})

            for link in page.get_links():
                rect = link["from"]
                # The top edge of a hyperlink is slightly above its text baseline.
                key, _ = locate(rect.y0 + (0.3 if page_number <= 5 else 0.7))
                if key is None:
                    raise ValueError(f"Сторінка {page_number}: посилання поза відомою областю таблиці.")
                row = rows.setdefault(key, {"cells": defaultdict(list), "spans": [], "links": []})
                row["links"].append({"uri": link.get("uri"), "bbox": list(rect), "kind": link["kind"]})

            for (section, row_index), row in sorted(rows.items()):
                cells = {field: "\n".join(values) for field, values in row["cells"].items()}
                links = [link["uri"] for link in row["links"] if link["uri"]]
                yield row_record(
                    {"page": page_number, "section": section + 1, "row": row_index + 1},
                    cells, links, {"spans": row["spans"], "links": row["links"], "cells": cells}
                )


def xlsx_rows(path):
    from openpyxl import load_workbook

    workbook = load_workbook(path, data_only=False, keep_links=False)
    try:
        for sheet in workbook.worksheets:
            columns = {}
            for cells in sheet.iter_rows():
                values = {c.column: str(c.value) for c in cells if c.value is not None}
                if not values:
                    continue
                recognized = {column: ALIASES.get(normalized(value)) for column, value in values.items()}
                if "name" in recognized.values() and sum(bool(v) for v in recognized.values()) >= 2:
                    columns = {column: field for column, field in recognized.items() if field}
                    continue
                mapped = {}
                for c in cells:
                    if c.column not in values or c.column not in columns:
                        continue
                    value = values[c.column]
                    # Preserve literal text and explicit leading zero number formats.
                    if isinstance(c.value, int) and isinstance(c.number_format, str) and re.fullmatch(r"0+", c.number_format):
                        value = str(c.value).zfill(len(c.number_format))
                    mapped[columns[c.column]] = value
                links = [c.hyperlink.target for c in cells if c.hyperlink and c.hyperlink.target
                         and columns.get(c.column) == "photo"]
                raw = {c.coordinate: {"value": values[c.column], "format": c.number_format,
                                      "type": c.data_type,
                                      "hyperlink": c.hyperlink.target if c.hyperlink else None}
                       for c in cells if c.column in values}
                yield row_record({"sheet": sheet.title, "row": cells[0].row}, mapped, links, raw)
    finally:
        workbook.close()


def classify(rows):
    by_number, by_name = defaultdict(list), defaultdict(list)
    for row in rows:
        if row["inventory_number"]:
            by_number[normalized(row["inventory_number"])].append(row)
        if row["name"]:
            by_name[normalized(row["name"]).lstrip("- ")].append(row)
    for row in rows:
        issues = []
        if not row["name"]:
            issues.append("Відсутня назва або потрібна перевірка меж рядка")
        if not row["inventory_number"]:
            issues.append("Відсутній первинний інвентарний номер")
        if row["quantity_decimal"] is None or Decimal(row["quantity_decimal"]) <= 0:
            issues.append("Кількість потребує перевірки")
        if row["initial_value"] and row["initial_value_decimal"] is None:
            issues.append("Первісна вартість потребує перевірки")
        if not row["warehouse"]:
            issues.append("Не вказано склад")
        if not row["tracking_type"]:
            issues.append("Потрібно визначити тип обліку")
        if row["name"] and row["name"].endswith(":"):
            issues.append("Можливий заголовок групи або комплекту")
        if any(entry.get("type") == "f" for entry in row["raw"].values() if isinstance(entry, dict)):
            issues.append("Формула потребує перевірки вихідного значення")
        duplicates = by_number.get(normalized(row["inventory_number"]), [])
        names = by_name.get(normalized(row["name"]).lstrip("- "), [])
        if len(duplicates) > 1:
            issues.append("Повторюється інвентарний номер")
        if len(names) > 1 and any(not other["inventory_number"] for other in names):
            issues.append("Збіг назви з позицією без номера")
        row["issues"] = issues
        row["duplicate_candidates"] = [
            other["source"] for other in (duplicates if len(duplicates) > 1 else
                                         names if any(not obj["inventory_number"] for obj in names) else [])
            if other is not row
        ]
    return {number: [r["source"] for r in group] for number, group in by_number.items() if len(group) > 1}


def html_table(rows):
    headings = ("Джерело", "Вид", "Назва", "Інвентарний №", "Кількість", "Первісна вартість",
                "Фото", "Склад", "Опис і коментар", "Потрібно перевірити")
    header = "".join(f"<th>{h}</th>" for h in headings)
    body = []
    for row in rows:
        src = row["source"]
        location = f"стор. {src['page']}, блок {src['section']}, рядок {src['row']}" if "page" in src else f"{src['sheet']}, рядок {src['row']}"
        values = (location, row["kind"], row["name"], row["inventory_number"],
                  row["quantity"] or row["quantity_decimal"], row["initial_value"],
                  "\n".join(row["photo_links"]) or row["photo"], row["warehouse"],
                  "\n".join(x for x in (row["description"], row["comment"]) if x),
                  "\n".join(row["issues"]))
        body.append("<tr>" + "".join(f"<td>{escape(str(value)) if value is not None else ''}</td>" for value in values) + "</tr>")
    return f"<table><thead><tr>{header}</tr></thead><tbody>{''.join(body)}</tbody></table>"


def main():
    parser = argparse.ArgumentParser(description="Підготувати локальний попередній перегляд обліку майна")
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    suffix = args.input.suffix.lower()
    if suffix not in {".pdf", ".xlsx"}:
        parser.error("Підтримуються PDF відомого шаблону та XLSX.")
    rows = list(pdf_rows(args.input) if suffix == ".pdf" else xlsx_rows(args.input))
    if not rows:
        parser.error("Не знайдено рядків у файлі.")
    duplicates = classify(rows)
    review = [row for row in rows if any(issue != "Потрібно визначити тип обліку" for issue in row["issues"])]
    summary = {
        "rows": len(rows), "review": len(review), "duplicate_numbers": len(duplicates),
        "photo_link_rows": sum(bool(r["photo_links"]) for r in rows),
        "rows_with_inventory_number": sum(bool(r["inventory_number"]) for r in rows),
        "rows_with_initial_value": sum(r["initial_value_decimal"] is not None for r in rows),
        "by_page_or_sheet": dict(Counter(str(r["source"].get("page", r["source"].get("sheet"))) for r in rows)),
        "issues": dict(Counter(issue for r in rows for issue in r["issues"])),
    }
    args.output.mkdir(mode=0o700, parents=True, exist_ok=True)
    # Review files may contain company values and private file references.
    for name in ("preview.json", "review.json", "preview.html", "review.html"):
        if (args.output / name).exists():
            parser.error(f"Файл {name} уже існує. Оберіть нову теку для перегляду.")
    payload = {"source_file": args.input.name, "sha256": sha256(args.input.read_bytes()).hexdigest(),
               "summary": summary, "duplicate_numbers": duplicates, "rows": rows}
    (args.output / "preview.json").write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    (args.output / "review.json").write_text(json.dumps(review, ensure_ascii=False, indent=2), encoding="utf-8")
    for name, title, data in (("preview", "Попередній перегляд", rows), ("review", "Неоднозначні позиції", review)):
        html = (
            '<!doctype html><html lang="uk"><meta charset="utf-8"><meta name="viewport" content="width=device-width">'
            f"<title>{title}</title><style>body{{font:14px system-ui;margin:20px}}table{{border-collapse:collapse;width:100%}}"
            "td,th{border:1px solid #ddd;padding:6px;text-align:left;vertical-align:top;white-space:pre-line;overflow-wrap:anywhere}"
            "th{background:#eee;position:sticky;top:0}</style>"
            f"<h1>{title}</h1><p>{escape(args.input.name)} · {len(data)} рядків</p>"
            '<p><a href="preview.html">Усі рядки</a> · <a href="review.html">Неоднозначні позиції</a></p>'
            + html_table(data)
        )
        (args.output / f"{name}.html").write_text(html, encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
