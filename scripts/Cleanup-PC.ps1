<#
.SYNOPSIS
    Cleans temporary files, caches, and other disk-wasting artifacts from a Windows PC.

.DESCRIPTION
    Performs a comprehensive PC cleanup including:
    - Windows temp files and user temp files
    - Windows Update cache
    - Browser caches (Chrome, Edge, Firefox)
    - Recycle Bin contents
    - Old log files (beyond retention period)

    Displays a summary of disk space recovered. Supports -WhatIf to preview
    actions without making changes.

.PARAMETER RetentionDays
    Number of days to retain log files. Files older than this are removed.
    Defaults to 30.

.PARAMETER SkipBrowserCache
    Skip clearing browser cache directories.

.PARAMETER SkipRecycleBin
    Skip emptying the Recycle Bin.

.EXAMPLE
    .\Cleanup-PC.ps1 -WhatIf
    Preview all cleanup actions without deleting anything.

.EXAMPLE
    .\Cleanup-PC.ps1 -Verbose
    Run full cleanup with detailed output.

.EXAMPLE
    .\Cleanup-PC.ps1 -RetentionDays 14 -SkipBrowserCache
    Clean up logs older than 14 days but skip browser caches.

.NOTES
    Author:  Bastiaan Rusch
    Version: 1.0.0
    Requires administrator privileges for full cleanup.
#>

#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidateRange(1, 365)]
    [int]$RetentionDays = 30,

    [switch]$SkipBrowserCache,

    [switch]$SkipRecycleBin
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# Import shared module
$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'modules\ITToolkit.psm1'
if (Test-Path $modulePath) {
    Import-Module $modulePath -Force
}

# ---------------------------------------------------------------------------
# Helper: safely remove items and track bytes freed
# ---------------------------------------------------------------------------
function Remove-ItemsSafely {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Path,
        [string]$Description,
        [string]$Filter = '*',
        [switch]$Recurse
    )

    if (-not (Test-Path -Path $Path)) {
        Write-Verbose "$Description - path not found: $Path"
        return 0
    }

    $items = Get-ChildItem -Path $Path -Filter $Filter -Recurse:$Recurse -Force -ErrorAction SilentlyContinue
    $totalBytes = ($items | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
    if (-not $totalBytes) { $totalBytes = 0 }

    $count = ($items | Measure-Object).Count
    Write-Verbose "$Description - found $count items ($([math]::Round($totalBytes / 1MB, 2)) MB)"

    foreach ($item in $items) {
        try {
            if ($PSCmdlet.ShouldProcess($item.FullName, "Delete ($Description)")) {
                Remove-Item -Path $item.FullName -Force -Recurse -ErrorAction SilentlyContinue
            }
        }
        catch {
            Write-Warning "Could not remove: $($item.FullName) - $($_.Exception.Message)"
        }
    }

    return $totalBytes
}

# ---------------------------------------------------------------------------
# Main cleanup
# ---------------------------------------------------------------------------

Write-Host "`n=== PC Cleanup Script ===" -ForegroundColor Cyan
Write-Host "Computer: $env:COMPUTERNAME"
Write-Host "Date:     $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "Mode:     $(if ($WhatIfPreference) { 'WhatIf (preview only)' } else { 'Live' })`n"

$totalRecovered = 0

# --- 1. Windows Temp ---
Write-Host "[1/6] Windows Temp Files..." -ForegroundColor Yellow
$totalRecovered += Remove-ItemsSafely -Path "$env:SystemRoot\Temp" `
    -Description 'Windows Temp' -Recurse

# --- 2. User Temp ---
Write-Host "[2/6] User Temp Files..." -ForegroundColor Yellow
$totalRecovered += Remove-ItemsSafely -Path $env:TEMP `
    -Description 'User Temp' -Recurse

# --- 3. Windows Update Cache ---
Write-Host "[3/6] Windows Update Cache..." -ForegroundColor Yellow
$wuCachePath = "$env:SystemRoot\SoftwareDistribution\Download"
$totalRecovered += Remove-ItemsSafely -Path $wuCachePath `
    -Description 'Windows Update Cache' -Recurse

# --- 4. Browser Caches ---
if (-not $SkipBrowserCache) {
    Write-Host "[4/6] Browser Caches..." -ForegroundColor Yellow

    # Chrome
    $chromeCachePath = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default\Cache'
    $totalRecovered += Remove-ItemsSafely -Path $chromeCachePath `
        -Description 'Chrome Cache' -Recurse

    # Edge
    $edgeCachePath = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data\Default\Cache'
    $totalRecovered += Remove-ItemsSafely -Path $edgeCachePath `
        -Description 'Edge Cache' -Recurse

    # Firefox
    $firefoxProfiles = Join-Path $env:LOCALAPPDATA 'Mozilla\Firefox\Profiles'
    if (Test-Path $firefoxProfiles) {
        $profiles = Get-ChildItem -Path $firefoxProfiles -Directory -ErrorAction SilentlyContinue
        foreach ($profile in $profiles) {
            $ffCachePath = Join-Path $profile.FullName 'cache2\entries'
            $totalRecovered += Remove-ItemsSafely -Path $ffCachePath `
                -Description "Firefox Cache ($($profile.Name))" -Recurse
        }
    }
}
else {
    Write-Host "[4/6] Browser Caches - SKIPPED" -ForegroundColor DarkGray
}

# --- 5. Recycle Bin ---
if (-not $SkipRecycleBin) {
    Write-Host "[5/6] Recycle Bin..." -ForegroundColor Yellow
    if ($PSCmdlet.ShouldProcess('Recycle Bin', 'Empty')) {
        try {
            Clear-RecycleBin -Force -ErrorAction SilentlyContinue
            Write-Verbose 'Recycle Bin emptied'
        }
        catch {
            Write-Warning "Could not empty Recycle Bin: $($_.Exception.Message)"
        }
    }
}
else {
    Write-Host "[5/6] Recycle Bin - SKIPPED" -ForegroundColor DarkGray
}

# --- 6. Old Log Files ---
Write-Host "[6/6] Old Log Files (> $RetentionDays days)..." -ForegroundColor Yellow
$logPaths = @(
    "$env:SystemRoot\Logs",
    "$env:SystemRoot\System32\LogFiles",
    "$env:ProgramData\Microsoft\Windows\WER\ReportQueue"
)
$cutoffDate = (Get-Date).AddDays(-$RetentionDays)

foreach ($logPath in $logPaths) {
    if (-not (Test-Path -Path $logPath)) { continue }

    $oldLogs = Get-ChildItem -Path $logPath -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { -not $_.PSIsContainer -and $_.LastWriteTime -lt $cutoffDate }

    $logBytes = ($oldLogs | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
    if (-not $logBytes) { $logBytes = 0 }
    $totalRecovered += $logBytes

    foreach ($log in $oldLogs) {
        try {
            if ($PSCmdlet.ShouldProcess($log.FullName, "Delete old log")) {
                Remove-Item -Path $log.FullName -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
            Write-Warning "Could not remove log: $($log.FullName)"
        }
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
$recoveredMB = [math]::Round($totalRecovered / 1MB, 2)
$recoveredGB = [math]::Round($totalRecovered / 1GB, 2)

Write-Host "`n=== Cleanup Summary ===" -ForegroundColor Green
Write-Host "Space recovered: $recoveredMB MB ($recoveredGB GB)"
if ($WhatIfPreference) {
    Write-Host "(WhatIf mode - no files were actually deleted)" -ForegroundColor DarkYellow
}
Write-Host ""

if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
    Write-Log -Message "PC Cleanup completed. Recovered: $recoveredMB MB" -Level Information
}
