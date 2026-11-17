# Current Readiness - HomeRescue AI

## Verified here in the preparation container

- [x] Inspected both copies of the original source repository; byte-for-byte identical.
- [x] Found all four source CSV export members inside the 2026-11-12 user ZIP.
- [x] Recovered complete, scope-filtered Buildings (`22,404`) and OMO (`490`) inputs.
- [x] Detected embedded `Internal error 500` payloads inside Complaints and Violations export members. They are incomplete and intentionally excluded from `data/raw/`.
- [x] Checked the data schema mapping against SQL loader column definitions (23/33/41/32 source columns).
- [x] Created source audit, instructor-friendly folder layout, clean live-demo SQL, and a guarded end-to-end Windows runner.
- [x] Retained teammate's original reports only in `docs/PREVIOUS_RUN_REFERENCE/`.
- [ ] Complaints & Violations 2024 **complete** inputs: runner must fetch via official NYC API on Windows Internet.
- [ ] Actual SQL execution on user's `localhost`: must happen when runner is executed on that PC.
- [ ] 3 **current** reports and `.bak`: generated on that PC after successful execution and checks.

**Do not present this ZIP as a fully executed SQL Server backup.** It contains the full preparation, SQL logic, evidence framework and two usable filtered datasets; a Windows run is still required to populate the DB and generate current reports.
