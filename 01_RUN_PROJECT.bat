@echo off
chcp 65001 >nul
cd /d "%~dp0"
title HomeRescue AI - SQL Server Bronze Silver Gold Setup
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0RUN_PROJECT.ps1"
if errorlevel 1 (
 echo.
 echo SETUP INCOMPLETE. Review the error above or RUN_LOG.txt.
) else (
 echo.
 echo Setup finished. Open the Bronze, Silver, Gold folders and SSMS.
)
pause
