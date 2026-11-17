# Bronze - evidence folder

- `00_init.sql` creates/initializes the database and `bronze`, `silver`, `gold`, `semantic`, `audit`, `ml` schemas.
- `01_bronze.sql` creates raw text tables, staging tables, source load procedures, and provenance columns.
- `BRONZE_REPORT.pdf` is generated **from the live database** by the main start script, after source checks and successful SQL execution.
- Evidence in SSMS: `06_Demo/DEMO_QUERIES.sql` section 1.
- The earlier teammate's PDF is preserved in `docs/PREVIOUS_RUN_REFERENCE/`; do **not** claim it describes the new database until verified.
