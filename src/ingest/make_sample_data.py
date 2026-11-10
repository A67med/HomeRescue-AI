import csv
from pathlib import Path

# 8 rows with deliberate problems: duplicate, bad date, negative amount, missing id, extra spaces, comma in number.
rows = [
    ["event_id", "entity_id", "entity_name", "category", "event_date", "amount", "updated_at"],
    ["E001", "A1", "Alpha ", "retail", "2026-01-05", "100.50", "2026-01-05 10:00"],
    ["E002", "A1", "Alpha", "retail", "2026-01-06", "200.00", "2026-01-06 10:00"],
    ["E003", "B1", "Beta", "corporate", "2026/01/07", "1,500.00", "2026-01-07 10:00"],
    ["E004", "B1", "Beta", "corporate", "not-a-date", "300.00", "2026-01-08 10:00"],
    ["E005", "C1", "Gamma", "smb", "2026-01-09", "-50.00", "2026-01-09 10:00"],
    ["E002", "A1", "Alpha", "retail", "2026-01-06", "250.00", "2026-01-10 10:00"],
    ["", "D1", "Delta", "retail", "2026-01-11", "75.00", "2026-01-11 10:00"],
    ["E008", "C1", "Gamma", "smb", "2026-01-12", "80.00", "2026-01-12 10:00"],
]
out = Path("data/raw/source_a.csv")
out.parent.mkdir(parents=True, exist_ok=True)
with out.open("w", newline="", encoding="utf-8") as f:
    csv.writer(f).writerows(rows)
print("Wrote", out.resolve())
