# Gold - evidence folder

- `03_gold.sql` builds the star schema: `gold.dim_building`, `gold.dim_date`, atomic fact tables and `gold.mart_building_month`.
- `05_feature_views.sql` builds `gold.features_building_maintenance`.
- `04_semantic.sql` builds `semantic.v_*` views and metric catalog; `metrics.yml` declares 12 semantic metrics.
- `06_analytics.sql` has five analytical SQL examples.
- `GOLD_REPORT.pdf` is regenerated **from the live database** after a successful build and validation.
- In SSMS: `06_Demo/DEMO_QUERIES.sql` section 3.

The actual fact/table/view names above are authoritative; the teammate's old README/demo contains some outdated names.
