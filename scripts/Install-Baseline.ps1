<#
.SYNOPSIS
    Installs a standard software baseline and configures Windows settings for new workstations.

.DESCRIPTION
    Automates new workstation setup by:
    - Installing common applications via winget (package manager)
    - Configuring Windows UI settings (dark mode, file extensions, etc.)
    - Applying organization-standard Windows settings
    - Optionally disabling telemetry and Cortana

    The application list can be loaded from a config file or settings.json.

.PARAMETER ConfigFile
    Path to a JSON config file containing the app list. Overrides settings.json.

.PARAMETER SkipApps
    Skip software installation; only apply Windows settings.

.PARAMETER SkipSettings
    Skip Windows settings; only install software.

.PARAMETER AppList
    Explicit list of winget package IDs to install. Overrides config file.

.EXAMPLE
    .\Install-Baseline.ps1
    Install all baseline apps from settings.json and apply Windows settings.

.EXAMPLE
    .\Install-Baseline.ps1 -WhatIf
    Preview what would be installed and configured.

.EXAMPLE
    .\Install-Baseline.ps1 -ConfigFile "C:\Config\apps.json" -SkipSettings
    Install apps from a custom config, skip Windows settings.

.EXAMPLE
    .\Install-Baseline.ps1 -AppList "Google.Chrome","7zip.7zip" -SkipSettings
    Install only Chrome and 7-Zip.

.NOTES
    Author:  Bastiaan Rusch
    Version: 1.0.0
    Requires: winget (App Installer), administrator privileges for Windows settings
#>

#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidateScript({
        if ($_ -and -not (Test-Path $_)) {
            throw "Config file not found: $_"
        }
        return $true
    })]
    [string]$ConfigFile,

    [switch]$SkipApps,

    [switch]$SkipSettings,

    [string[]]$AppList
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# Import shared module
$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'modules\ITToolkit.psm1'
if (Test-Path $modulePath) {
    Import-Module $modulePath -Force
}

# ---------------------------------------------------------------------------
# Load configuration
# ---------------------------------------------------------------------------
$apps = @()
$windowsSettings = $null

if ($AppList) {
    $apps = $AppList | ForEach-Object {
        [PSCustomObject]@{ Id = $_; Name = $_ }
    }
}
elseif ($ConfigFile) {
    $customConfig = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
    $apps = $customConfig.BaselineApps
    if ($customConfig.WindowsSettings) {
        $windowsSettings = $customConfig.WindowsSettings
    }
}
else {
    try {
        $config = Get-Config
        $apps = $config.BaselineApps
        $windowsSettings = $config.WindowsSettings
    }
    catch {
        Write-Warning "Could not load config. Using built-in defaults."
        $apps = @(
            [PSCustomObject]@{ Id = 'Google.Chrome';           Name = 'Google Chrome' }
            [PSCustomObject]@{ Id = 'Mozilla.Firefox';         Name = 'Mozilla Firefox' }
            [PSCustomObject]@{ Id = '7zip.7zip';               Name = '7-Zip' }
            [PSCustomObject]@{ Id = 'Notepad++.Notepad++';     Name = 'Notepad++' }
            [PSCustomObject]@{ Id = 'Microsoft.Teams';         Name = 'Microsoft Teams' }
            [PSCustomObject]@{ Id = 'Adobe.Acrobat.Reader.64-bit'; Name = 'Adobe Acrobat Reader' }
            [PSCustomObject]@{ Id = 'VideoLAN.VLC';            Name = 'VLC Media Player' }
            [PSCustomObject]@{ Id = 'Microsoft.PowerShell';    Name = 'PowerShell 7' }
        )
    }
}

if (-not $windowsSettings) {
    $windowsSettings = [PSCustomObject]@{
        EnableDarkMode              = $true
        ShowFileExtensions          = $true
        ShowHiddenFiles             = $false
        DisableTelemetry            = $true
        DisableCortana              = $true
        SetPowerPlanHighPerformance = $true
    }
}

Write-Host "`n=== Workstation Baseline Installer ===" -ForegroundColor Cyan
Write-Host "Computer: $env:COMPUTERNAME"
Write-Host "Date:     $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "Mode:     $(if ($WhatIfPreference) { 'WhatIf (preview only)' } else { 'Live' })`n"

# ---------------------------------------------------------------------------
# Check winget availability
# ---------------------------------------------------------------------------
if (-not $SkipApps) {
    $wingetPath = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $wingetPath) {
        Write-Warning "winget is not installed or not in PATH. App installation will be skipped."
        Write-Warning "Install App Installer from the Microsoft Store or via: https://aka.ms/getwinget"
        $SkipApps = $true
    }
}

# ---------------------------------------------------------------------------
# Install Applications
# ---------------------------------------------------------------------------
if (-not $SkipApps) {
    Write-Host "=== Installing Applications ===" -ForegroundColor Yellow
    Write-Host "Apps to install: $($apps.Count)`n"

    $results = [System.Collections.ArrayList]::new()

    foreach ($app in $apps) {
        $appId   = $app.Id
        $appName = $app.Name

        Write-Host "  [$($results.Count + 1)/$($apps.Count)] $appName ($appId)..." -NoNewline

        if ($PSCmdlet.ShouldProcess($appName, "Install via winget ($appId)")) {
            try {
                # Check if already installed
                $installed = winget list --id $appId --accept-source-agreements 2>$null
                if ($LASTEXITCODE -eq 0 -and $installed -match $appId) {
                    Write-Host " Already installed" -ForegroundColor DarkGray
                    [void]$results.Add([PSCustomObject]@{
                        App    = $appName
                        Id     = $appId
                        Status = 'Already Installed'
                    })
                    continue
                }

                # Install
                $output = winget install --id $appId --accept-source-agreements --accept-package-agreements --silent 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Host " Installed" -ForegroundColor Green
                    [void]$results.Add([PSCustomObject]@{
                        App    = $appName
                        Id     = $appId
                        Status = 'Installed'
                    })
                }
                else {
                    Write-Host " Failed" -ForegroundColor Red
                    [void]$results.Add([PSCustomObject]@{
                        App    = $appName
                        Id     = $appId
                        Status = "Failed: $output"
                    })
                }
            }
            catch {
                Write-Host " Error" -ForegroundColor Red
                [void]$results.Add([PSCustomObject]@{
                    App    = $appName
                    Id     = $appId
                    Status = "Error: $($_.Exception.Message)"
                })
            }
        }
        else {
            Write-Host " Skipped (WhatIf)" -ForegroundColor DarkYellow
            [void]$results.Add([PSCustomObject]@{
                App    = $appName
                Id     = $appId
                Status = 'WhatIf'
            })
        }
    }

    Write-Host "`nInstallation Results:" -ForegroundColor Yellow
    $results | Format-Table -AutoSize
}

# ---------------------------------------------------------------------------
# Configure Windows Settings
# ---------------------------------------------------------------------------
if (-not $SkipSettings) {
    Write-Host "=== Configuring Windows Settings ===" -ForegroundColor Yellow

    # --- Dark Mode ---
    if ($windowsSettings.EnableDarkMode) {
        if ($PSCmdlet.ShouldProcess('Windows Theme', 'Enable dark mode')) {
            Write-Host "  Enabling dark mode..." -NoNewline
            try {
                $themePath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'
                if (-not (Test-Path $themePath)) {
                    New-Item -Path $themePath -Force | Out-Null
                }
                Set-ItemProperty -Path $themePath -Name 'AppsUseLightTheme' -Value 0 -Type DWord
                Set-ItemProperty -Path $themePath -Name 'SystemUsesLightTheme' -Value 0 -Type DWord
                Write-Host " Done" -ForegroundColor Green
            }
            catch {
                Write-Host " Failed: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }

    # --- Show File Extensions ---
    if ($windowsSettings.ShowFileExtensions) {
        if ($PSCmdlet.ShouldProcess('Explorer', 'Show file extensions')) {
            Write-Host "  Showing file extensions..." -NoNewline
            try {
                $explorerPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
                Set-ItemProperty -Path $explorerPath -Name 'HideFileExt' -Value 0 -Type DWord
                Write-Host " Done" -ForegroundColor Green
            }
            catch {
                Write-Host " Failed: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }

    # --- Show Hidden Files ---
    if ($windowsSettings.ShowHiddenFiles) {
        if ($PSCmdlet.ShouldProcess('Explorer', 'Show hidden files')) {
            Write-Host "  Showing hidden files..." -NoNewline
            try {
                $explorerPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
                Set-ItemProperty -Path $explorerPath -Name 'Hidden' -Value 1 -Type DWord
                Write-Host " Done" -ForegroundColor Green
            }
            catch {
                Write-Host " Failed: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }

    # --- Disable Telemetry ---
    if ($windowsSettings.DisableTelemetry) {
        if ($PSCmdlet.ShouldProcess('Windows Telemetry', 'Disable telemetry')) {
            Write-Host "  Disabling telemetry..." -NoNewline
            try {
                $telemetryPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
                if (-not (Test-Path $telemetryPath)) {
                    New-Item -Path $telemetryPath -Force | Out-Null
                }
                Set-ItemProperty -Path $telemetryPath -Name 'AllowTelemetry' -Value 0 -Type DWord
                Write-Host " Done" -ForegroundColor Green
            }
            catch {
                Write-Host " Failed (may require admin): $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }

    # --- Disable Cortana ---
    if ($windowsSettings.DisableCortana) {
        if ($PSCmdlet.ShouldProcess('Cortana', 'Disable Cortana')) {
            Write-Host "  Disabling Cortana..." -NoNewline
            try {
                $cortanaPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'
                if (-not (Test-Path $cortanaPath)) {
                    New-Item -Path $cortanaPath -Force | Out-Null
                }
                Set-ItemProperty -Path $cortanaPath -Name 'AllowCortana' -Value 0 -Type DWord
                Write-Host " Done" -ForegroundColor Green
            }
            catch {
                Write-Host " Failed (may require admin): $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }

    # --- Power Plan ---
    if ($windowsSettings.SetPowerPlanHighPerformance) {
        if ($PSCmdlet.ShouldProcess('Power Plan', 'Set to High Performance')) {
            Write-Host "  Setting High Performance power plan..." -NoNewline
            try {
                $highPerfGuid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
                powercfg /setactive $highPerfGuid
                Write-Host " Done" -ForegroundColor Green
            }
            catch {
                Write-Host " Failed: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }

    Write-Host ""
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host "=== Baseline Installation Complete ===" -ForegroundColor Green
if ($WhatIfPreference) {
    Write-Host "(WhatIf mode - no changes were made)" -ForegroundColor DarkYellow
}
Write-Host ""

if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
    Write-Log -Message "Baseline installation completed on $env:COMPUTERNAME"
}
