"""Prepare the private JSON package accepted by Stage Base inventory intake."""
import argparse
import json
from pathlib import Path

from catalog_review import prepare


TRACKING = {"Окремий предмет": "individual", "Комплект": "set", "Витратний матеріал": "consumable"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("preview", type=Path)
    parser.add_argument("existing", type=Path)
    parser.add_argument("package", type=Path)
    args = parser.parse_args()
    source = json.loads(args.preview.read_text())
    existing = json.loads(args.existing.read_text())
    items = []
    excluded = []
    for original, prepared in prepare(source, existing):
        ref = original["source"]
        identity = (f"pdf:{ref['page']}:{ref['section']}:{ref['row']}" if "page" in ref
                    else f"xlsx:{ref['sheet']}:{ref['row']}")
        if not prepared["number"] or not prepared["name"]:
            excluded.append(identity)
            continue
        items.append({
            "source_row": identity,
            "inventory_number": prepared["number"],
            "original_number": original["inventory_number"],
            "name": prepared["name"],
            "description": prepared["details"],
            "comment": prepared["comment"],
            "warehouse_hint": prepared["warehouse"],
            "quantity": prepared["quantity"],
            "unit": prepared["unit"],
            "tracking_type": TRACKING.get(prepared["tracking"]),
            "category": prepared["category"],
            "review": prepared["review"],
            "photo_links": original["photo_links"],
            "original": {key: original[key] for key in (
                "kind", "name", "quantity", "initial_value", "inventory_number",
                "photo", "warehouse", "description", "comment"
            )},
        })
    with args.package.open("x", encoding="utf-8") as output:
        json.dump({"source_sha256": source["sha256"], "items": items, "excluded": excluded}, output,
                  ensure_ascii=False, separators=(",", ":"))
    print(f"Позицій у пакеті: {len(items)}. Рядків поза пакетом для звірки: {len(excluded)}.")


if __name__ == "__main__":
    main()
