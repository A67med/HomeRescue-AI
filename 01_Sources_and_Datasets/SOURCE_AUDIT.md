# Evidence from user-supplied full NYC export ZIP (2026-11-12)

| Member | Rows scanned in supplied member | Staten Island 2024 rows present | Result |
|---|---:|---:|---|
| Buildings | 381,934 | 22,404 | Structurally complete; included as `buildings.csv` |
| Complaints and Problems | 820,267 CSV rows, then 5 non-CSV error lines | 96 | **INCOMPLETE**; do not load |
| Violations | 2,781,255 CSV rows, then 5 non-CSV error lines | 10,331 | **INCOMPLETE**; do not load |
| OMO Charges | 516,939 | 490 | Structurally complete; included as `omo_charges.csv` |

The two failed CSV exports ended with JSON containing `"error": true`, `"message": "Internal error"`, `"status": 500`. The ZIP is valid, but the CSV payloads were interrupted at the source; CRC integrity of the ZIP does not make the underlying source download complete.

The originally reported 2024 counts were: 22,404 buildings, 14,377 complaint problems, 18,463 violations and 490 OMO charges (55,734). These previous numbers are a *comparison only*, not evidence of today's SQL results. Results from the local SQL run may change if the live source changes.

For source-to-warehouse auditing, `src/evaluation/verify_inputs.py` refuses to load missing, structurally invalid, wrong-borough/year, or unexpectedly tiny CSVs. `src/ingest/fetch_nyc_opendata.py` also checks API headers and its server-side pre/post row counts.
