# Silver - evidence folder

- `02_silver.sql` handles normalized IDs, typed dates/money, reject reasons, duplicates, and reconciliation.
- `SILVER_REPORT.pdf` is generated **from the live database** after successful SQL execution.
- In SSMS: `06_Demo/DEMO_QUERIES.sql` section 2.
- Rule: Bronze row count = Silver accepted + rejected + deduplicated.
