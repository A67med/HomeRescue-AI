@echo off
setlocal EnableExtensions
chcp 65001 >nul
cd /d "%~dp0"
title HomeRescue AI - Finish Reports Only (Safe Fix)
echo.
echo ==============================================
echo HomeRescue AI - Resume reports after SQL error
 echo ==============================================
echo.
if not exist "src\evaluation\generate_live_reports.py" (
  echo ERROR: This file must be inside your HomeRescue AI MAIN folder.
  echo Put these two patch files next to 01_RUN_PROJECT.bat and run again.
  goto :FAIL
)
if not exist "generate_live_reports_FIXED.py" (
  echo ERROR: Missing generate_live_reports_FIXED.py next to this BAT file.
  goto :FAIL
)
if not exist "data\exports\validation\quality_checks_results_homerescue_dw.json" (
  echo ERROR: Quality validation file is missing.
  echo The warehouse pipeline may not have finished. Do not mark the project complete.
  goto :FAIL
)
echo [1/4] Updating the broken report generator...
copy /Y "generate_live_reports_FIXED.py" "src\evaluation\generate_live_reports.py" >nul
if errorlevel 1 goto :FAIL

echo [2/4] Generating LIVE Bronze / Silver / Gold PDF reports...
py -3 -m src.evaluation.generate_live_reports
if errorlevel 1 goto :FAIL
if not exist "03_Bronze\BRONZE_REPORT.pdf" goto :FAIL
if not exist "04_Silver\SILVER_REPORT.pdf" goto :FAIL
if not exist "05_Gold\GOLD_REPORT.pdf" goto :FAIL

echo [3/4] Attempting SQL Server database backup (optional)...
py -3 -m src.evaluation.backup_database
if errorlevel 1 (
  echo WARNING: Backup could not be completed automatically.
  echo Check 07_Database_Backup or back up manually using SSMS.
  set "BACKUP_ERROR=1"
)

echo [4/4] Refreshing source CSVs and status...
if exist "data\raw\*.csv" copy /Y "data\raw\*.csv" "01_Sources_and_Datasets\" >nul
if exist "data\raw\manifest.json" copy /Y "data\raw\manifest.json" "01_Sources_and_Datasets\source_manifest.json" >nul
if defined BACKUP_ERROR (
  >"RUN_STATUS.txt" echo REPORTS_PASS_BACKUP_NEEDS_CHECK
  echo.
  echo REPORTS SUCCESS! But database backup requires attention.
  echo Open 07_Database_Backup and confirm the .bak file.
) else (
  >"RUN_STATUS.txt" echo REPORTS_PASS_CHECK_BACKUP_FOLDER
  echo.
  echo REPORTS SUCCESS! Verify the backup .bak in 07_Database_Backup.
)
echo Open 03_Bronze, 04_Silver, 05_Gold for current PDF reports.
echo Run 02_OPEN_FOR_EVALUATION.bat to open the evaluation documents.
echo.
pause
exit /b 0
:FAIL
echo.
echo ERROR: Reports could not be completed. Do NOT rerun the full pipeline yet.
echo Copy or screenshot the message ABOVE and send it to ChatGPT.
>"RUN_STATUS.txt" echo INCOMPLETE_REPORT_FIX_ERROR
echo.
pause
exit /b 1
