@echo off
cd /d "%~dp0"
if not exist "03_Bronze\BRONZE_REPORT.pdf" (
 echo Current reports not found. Run 01_RUN_PROJECT.bat first.
 pause
 exit /b 1
)
if not exist "04_Silver\SILVER_REPORT.pdf" (
 echo Silver report missing. Run 01_RUN_PROJECT.bat first.
 pause
 exit /b 1
)
if not exist "05_Gold\GOLD_REPORT.pdf" (
 echo Gold report missing. Run 01_RUN_PROJECT.bat first.
 pause
 exit /b 1
)
start "" "01_Sources_and_Datasets\SOURCE_LINKS.md"
start "" "02_Idea_Question\IDEA_QUESTION.md"
start "" "03_Bronze\00_init.sql"
start "" "03_Bronze\01_bronze.sql"
start "" "03_Bronze\BRONZE_REPORT.pdf"
start "" "04_Silver\02_silver.sql"
start "" "04_Silver\SILVER_REPORT.pdf"
start "" "05_Gold\03_gold.sql"
start "" "05_Gold\04_semantic.sql"
start "" "05_Gold\05_feature_views.sql"
start "" "05_Gold\06_analytics.sql"
start "" "05_Gold\GOLD_REPORT.pdf"
start "" "06_Demo\DEMO_QUERIES.sql"
start "" "01_Sources_and_Datasets"
start "" "07_Database_Backup"
echo All available evaluation files have been opened with your Windows default apps.
