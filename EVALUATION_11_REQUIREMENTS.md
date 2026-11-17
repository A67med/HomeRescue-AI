# Evaluation submission tracker - 11 instructor items

| Instructor requirement | Folder | Before local run | After successful local run |
|---|---|---|---|
| 1. Sources links and datasets | `01_Sources_and_Datasets` | URLs + Buildings & OMO only; broken other 2 exports excluded | 4 validated CSVs plus manifest |
| 2. Idea question | `02_Idea_Question/IDEA_QUESTION.md` | Ready | Ready |
| 3. Bronze SQL script | `03_Bronze/01_bronze.sql` | Ready | Ready |
| 4. Bronze database | `homerescue_dw.bronze` in SSMS | Not populated on user's PC | 4 populated Bronze tables |
| 5. Bronze report | `03_Bronze/BRONZE_REPORT.pdf` | Previous-run reference only | New PDF from local SQL |
| 6. Silver SQL script | `04_Silver/02_silver.sql` | Ready | Ready |
| 7. Silver database | `homerescue_dw.silver` in SSMS | Not populated on user's PC | Cleaned tables and rejection logs |
| 8. Silver report | `04_Silver/SILVER_REPORT.pdf` | Previous-run reference only | New PDF from local SQL |
| 9. Gold script | `05_Gold/*.sql` | Ready | Ready |
| 10. Gold database | `homerescue_dw.gold` in SSMS; optional `.bak` in `07_Database_Backup` | Not populated on user's PC | Dimensions, facts, semantic features; native `.bak` attempted |
| 11. Gold report | `05_Gold/GOLD_REPORT.pdf` | Previous-run reference only | New PDF from local SQL |

**Do not misrepresent status:** A report generated in the previous teammate's environment is evidence of that earlier environment only. The current reports are generated only if local warehouse execution and all automated checks pass.

The original SQL schema design uses a **single SQL Server database** with separate Bronze, Silver, and Gold schemas. It does not require three independent `.bak` backups or three separate databases.
