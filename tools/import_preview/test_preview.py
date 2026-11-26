import tempfile
from pathlib import Path
import unittest

from openpyxl import Workbook

from preview import classify, html_table, xlsx_rows


class PreviewTest(unittest.TestCase):
    def test_workbook_preserves_numbers_values_and_links_across_sheets(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "test.xlsx"
            workbook = Workbook()
            for sheet in (workbook.active, workbook.create_sheet("Друга вкладка")):
                sheet.append(["Найменування", "Інвентарний №", "Кількість", "Первісна вартість", "Фото"])
            workbook.active.append(["<script>Назва</script>", 12, "2,5", "1 234,50", "фото"])
            workbook.active["B2"].number_format = "00000"
            workbook.active["E2"].hyperlink = "https://example.invalid/photo"
            workbook.active.append(["Однакова назва", "00013", 1, "=1+1"])
            second = workbook["Друга вкладка"]
            second.append(["Інша назва", "00012", 1, None])
            second.append(["Однакова назва", "00014", 1, None])
            workbook.save(path)
            rows = list(xlsx_rows(path))

        duplicates = classify(rows)
        self.assertEqual(list(duplicates), ["00012"])
        self.assertEqual(rows[0]["inventory_number"], "00012")
        self.assertEqual(rows[0]["quantity_decimal"], "2.5")
        self.assertEqual(rows[0]["initial_value_decimal"], "1234.50")
        self.assertEqual(rows[0]["photo_links"], ["https://example.invalid/photo"])
        self.assertEqual(rows[2]["source"]["sheet"], "Друга вкладка")
        self.assertIsNone(rows[1]["initial_value_decimal"])
        self.assertFalse(rows[3]["duplicate_candidates"])
        self.assertNotIn("<script>", html_table(rows))
        self.assertIn("&lt;script&gt;", html_table(rows))


if __name__ == "__main__":
    unittest.main()
