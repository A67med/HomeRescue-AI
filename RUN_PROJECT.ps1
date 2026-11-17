# HomeRescue AI evaluation setup for local Windows SQL Server instance.
# No destructive DROP DATABASE commands. Uses existing homerescue_dw.
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$python = $null
$pyArgs = @()

function Invoke-Py {
    param([string[]]$CliArgs)
    $exe = $script:python
    $prefix = $script:pyArgs
    & $exe @prefix @CliArgs
    if ($LASTEXITCODE -ne 0) { throw "Python command failed (exit code $LASTEXITCODE): $($CliArgs -join ' ')" }
}

try {
    Start-Transcript -Path (Join-Path $PSScriptRoot 'RUN_LOG.txt') -Append | Out-Null
    Write-Host 'HOME RESCUE AI - Automatic Bronze / Silver / Gold setup' -ForegroundColor Cyan
    Write-Host '[0/6] Detecting Python 3.10+...' -ForegroundColor Cyan
    # The Windows Python launcher was confirmed by the user: py -3 --version -> Python 3.12.6.
    # Avoid trying python/python3 aliases, which can stall on some Windows configurations.
    $python = 'py'
    $pyArgs = @('-3')
    Write-Host 'Using Windows Python launcher: py -3' -ForegroundColor Cyan
    & py -3 --version
    if ($LASTEXITCODE -ne 0) {
        throw 'Python launcher failed. Run py -3 --version in Command Prompt.'
    }
    Write-Host ('Python found: ' + $python) -ForegroundColor Green
    Write-Host '[1/6] Installing minimal Python modules...' -ForegroundColor Cyan
    Invoke-Py -CliArgs @('-m','pip','install','-r','requirements_evaluation.txt')

    Write-Host '[2/6] Checking local SQL Server connection...' -ForegroundColor Cyan
    Invoke-Py -CliArgs @('-m','src.evaluation.check_server')

    Write-Host '[3/6] Downloading COMPLETE 2024 Staten Island complaints and violations...' -ForegroundColor Cyan
    # The user's original two giant CSV exports are CORRUPT (embedded HTTP 500 at EOF).
    # Official SODA API subset is required before SQL ingestion. Guard enforces matched row counts.
    Invoke-Py -CliArgs @('-m','src.ingest.fetch_nyc_opendata','--only','complaints_problems','violations','--page-size','5000')

    Write-Host '[4/6] Auditing all four input CSVs BEFORE loading any tables...' -ForegroundColor Cyan
    Invoke-Py -CliArgs @('-m','src.evaluation.verify_inputs')

    Write-Host '[5/6] Creating and loading Bronze, Silver, Gold, Semantic and running QA...' -ForegroundColor Cyan
    Invoke-Py -CliArgs @('-m','src.run_pipeline','--target-db','homerescue_dw')

    Write-Host '[6/6] Generating CURRENT Bronze, Silver and Gold PDF reports from SQL...' -ForegroundColor Cyan
    Invoke-Py -CliArgs @('-m','src.evaluation.generate_live_reports')

    Write-Host 'Attempting optional native SQL Server backup...' -ForegroundColor Cyan
    try { Invoke-Py -CliArgs @('-m','src.evaluation.backup_database') } catch { Write-Host ('Backup warning: ' + $_.Exception.Message) -ForegroundColor Yellow }

    Copy-Item 'data/raw/*.csv' '01_Sources_and_Datasets/' -Force
    Copy-Item 'data/raw/manifest.json' '01_Sources_and_Datasets/source_manifest.json' -Force

    Write-Host 'SUCCESS: Live reports are now in 03_Bronze, 04_Silver, 05_Gold.' -ForegroundColor Green
    Write-Host 'Database: homerescue_dw. Open 06_Demo/DEMO_QUERIES.sql inside SSMS.' -ForegroundColor Green
    'PASS' | Set-Content -Path 'RUN_STATUS.txt' -Encoding UTF8
    exit 0
}
catch {
    Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    'INCOMPLETE - See RUN_LOG.txt; do not present previous-run PDFs as current results' | Set-Content -Path 'RUN_STATUS.txt' -Encoding UTF8
    exit 1
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
}
