# Official NYC Open Data - Source Links and Dataset IDs

**Project:** HomeRescue AI | **Geographic scope:** Staten Island (`boroid = 5`) | **Event year:** 2024.

1. Buildings Subject to HPD Jurisdiction (`kj4p-ruqc`) - https://data.cityofnewyork.us/d/kj4p-ruqc
2. Housing Maintenance Code Complaints and Problems (`ygpa-z7cr`) - https://data.cityofnewyork.us/d/ygpa-z7cr
3. Housing Maintenance Code Violations (`wvxf-dwi5`) - https://data.cityofnewyork.us/d/wvxf-dwi5
4. Open Market Order (OMO) Charges (`mdbu-nrqn`) - https://data.cityofnewyork.us/d/mdbu-nrqn

**Filter rules:** Complete reference population of Staten Island buildings; Staten Island 2024 complaints by `received_date`, 2024 violations by `inspectiondate`, and 2024 OMO charges by `omocreatedate`.

**Sources are independently refreshed.** Historic counts from the original teammate's Nov 10 report are NOT live proof of this computer's database. After `01_RUN_PROJECT.bat`, use `source_manifest.json` in this folder, showing SHA-256, actual local row counts, and source URLs.

Two CSVs (buildings and OMO) were extracted completely from the user-provided 2026-11-12 NYC Open Data ZIP. The complaints and violations members were truncated by embedded server `Internal error` HTTP 500 payloads; they are NOT passed off as complete. The start script re-acquires them from the official, scope-filtered Socrata API before any SQL load.
