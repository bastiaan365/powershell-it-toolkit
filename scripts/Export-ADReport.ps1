<#
.SYNOPSIS
    Exports Active Directory user reports in CSV or HTML format.

.DESCRIPTION
    Generates comprehensive AD reports including:
    - All users with last logon date, password expiry, and group memberships
    - Disabled accounts
    - Locked-out accounts
    - Accounts with expired passwords
    - Stale accounts (no logon within a configurable period)

    Output is written to CSV or a styled HTML report.

.PARAMETER OutputPath
    Directory where report files will be saved. Defaults to the current directory.

.PARAMETER Format
    Output format: CSV or HTML. Defaults to CSV.

.PARAMETER StaleDays
    Number of days since last logon to consider an account stale. Defaults to 90.

.PARAMETER SearchBase
    AD search base (OU). If omitted, searches the entire domain.

.PARAMETER IncludeServiceAccounts
    Include service accounts (accounts starting with 'svc-') in the report.

.EXAMPLE
    .\Export-ADReport.ps1 -OutputPath "C:\Reports" -Format HTML
    Generate an HTML report in C:\Reports.

.EXAMPLE
    .\Export-ADReport.ps1 -Format CSV -StaleDays 60
    Generate CSV reports flagging accounts inactive for 60+ days.

.EXAMPLE
    .\Export-ADReport.ps1 -SearchBase "OU=Corporate,DC=contoso,DC=com" -Format HTML

.NOTES
    Author:  Bastiaan Rusch
    Version: 1.0.0
    Requires: ActiveDirectory module (RSAT)
#>

#Requires -Version 5.1
#Requires -Modules ActiveDirectory

[CmdletBinding()]
param(
    [ValidateScript({
        if (-not (Test-Path -Path $_ -PathType Container)) {
            New-Item -Path $_ -ItemType Directory -Force | Out-Null
        }
        return $true
    })]
    [string]$OutputPath = '.',

    [ValidateSet('CSV', 'HTML')]
    [string]$Format = 'CSV',

    [ValidateRange(1, 365)]
    [int]$StaleDays = 90,

    [string]$SearchBase,

    [switch]$IncludeServiceAccounts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Import shared module
$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'modules\ITToolkit.psm1'
if (Test-Path $modulePath) {
    Import-Module $modulePath -Force
}

$timestamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$staleDate   = (Get-Date).AddDays(-$StaleDays)
$reportFiles = @()

# ---------------------------------------------------------------------------
# HTML styling
# ---------------------------------------------------------------------------
$htmlHead = @"
<style>
    body   { font-family: Segoe UI, Arial, sans-serif; margin: 20px; background: #f5f5f5; }
    h1     { color: #2c3e50; border-bottom: 2px solid #3498db; padding-bottom: 10px; }
    h2     { color: #2980b9; margin-top: 30px; }
    table  { border-collapse: collapse; width: 100%; margin-bottom: 20px; background: #fff; }
    th     { background: #3498db; color: white; padding: 10px 12px; text-align: left; }
    td     { padding: 8px 12px; border-bottom: 1px solid #ddd; }
    tr:nth-child(even) { background: #f2f2f2; }
    tr:hover { background: #e8f4fd; }
    .warning { color: #e67e22; font-weight: bold; }
    .critical { color: #e74c3c; font-weight: bold; }
    .ok { color: #27ae60; }
    .meta { color: #7f8c8d; font-size: 0.9em; margin-bottom: 20px; }
</style>
"@

# ---------------------------------------------------------------------------
# Helper: get AD users with common properties
# ---------------------------------------------------------------------------
function Get-ADUserData {
    [CmdletBinding()]
    param([string]$Base)

    $properties = @(
        'DisplayName', 'SamAccountName', 'UserPrincipalName', 'EmailAddress',
        'Department', 'Title', 'Manager', 'Enabled',
        'LastLogonDate', 'PasswordLastSet', 'PasswordExpired', 'PasswordNeverExpires',
        'LockedOut', 'Created', 'MemberOf', 'Description'
    )

    $params = @{
        Filter     = '*'
        Properties = $properties
    }
    if ($Base) { $params['SearchBase'] = $Base }

    $users = Get-ADUser @params

    if (-not $IncludeServiceAccounts) {
        $users = $users | Where-Object { $_.SamAccountName -notlike 'svc-*' }
    }

    return $users
}

# ---------------------------------------------------------------------------
# Collect data
# ---------------------------------------------------------------------------
Write-Host "`n=== Active Directory Report ===" -ForegroundColor Cyan
Write-Host "Date:       $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "Format:     $Format"
Write-Host "Output:     $OutputPath"
Write-Host "Stale Days: $StaleDays`n"

Write-Host "Collecting AD user data..." -ForegroundColor Yellow
$allUsers = Get-ADUserData -Base $SearchBase
Write-Host "  Found $($allUsers.Count) user accounts" -ForegroundColor Green

# --- All Users Report ---
Write-Host "Generating All Users report..." -ForegroundColor Yellow
$userReport = $allUsers | ForEach-Object {
    $groups = ($_.MemberOf | ForEach-Object {
        try { (Get-ADGroup $_).Name } catch { $_ }
    }) -join '; '

    $managerName = ''
    if ($_.Manager) {
        try { $managerName = (Get-ADUser $_.Manager).Name } catch { $managerName = $_.Manager }
    }

    $passwordAge = if ($_.PasswordLastSet) {
        [math]::Round(((Get-Date) - $_.PasswordLastSet).TotalDays)
    } else { 'Never Set' }

    [PSCustomObject]@{
        DisplayName         = $_.DisplayName
        SamAccountName      = $_.SamAccountName
        Email               = $_.EmailAddress
        Department          = $_.Department
        Title               = $_.Title
        Manager             = $managerName
        Enabled             = $_.Enabled
        LastLogon           = if ($_.LastLogonDate) { $_.LastLogonDate.ToString('yyyy-MM-dd') } else { 'Never' }
        PasswordLastSet     = if ($_.PasswordLastSet) { $_.PasswordLastSet.ToString('yyyy-MM-dd') } else { 'Never' }
        PasswordAgeDays     = $passwordAge
        PasswordExpired     = $_.PasswordExpired
        PasswordNeverExpires = $_.PasswordNeverExpires
        LockedOut           = $_.LockedOut
        Created             = $_.Created.ToString('yyyy-MM-dd')
        GroupMemberships    = $groups
    }
}

# --- Disabled Accounts ---
Write-Host "Identifying disabled accounts..." -ForegroundColor Yellow
$disabledAccounts = $userReport | Where-Object { $_.Enabled -eq $false }
Write-Host "  Found $($disabledAccounts.Count) disabled accounts" -ForegroundColor $(if ($disabledAccounts.Count -gt 0) { 'Yellow' } else { 'Green' })

# --- Locked Accounts ---
Write-Host "Identifying locked accounts..." -ForegroundColor Yellow
$lockedAccounts = $userReport | Where-Object { $_.LockedOut -eq $true }
Write-Host "  Found $($lockedAccounts.Count) locked accounts" -ForegroundColor $(if ($lockedAccounts.Count -gt 0) { 'Red' } else { 'Green' })

# --- Stale Accounts ---
Write-Host "Identifying stale accounts (no logon in $StaleDays days)..." -ForegroundColor Yellow
$staleAccounts = $userReport | Where-Object {
    $_.Enabled -eq $true -and ($_.LastLogon -eq 'Never' -or
        ([datetime]::TryParse($_.LastLogon, [ref](Get-Date)) -and [datetime]$_.LastLogon -lt $staleDate))
}
Write-Host "  Found $($staleAccounts.Count) stale accounts" -ForegroundColor $(if ($staleAccounts.Count -gt 0) { 'Yellow' } else { 'Green' })

# --- Expired Passwords ---
Write-Host "Identifying expired passwords..." -ForegroundColor Yellow
$expiredPasswords = $userReport | Where-Object { $_.Enabled -eq $true -and $_.PasswordExpired -eq $true }
Write-Host "  Found $($expiredPasswords.Count) accounts with expired passwords" -ForegroundColor $(if ($expiredPasswords.Count -gt 0) { 'Yellow' } else { 'Green' })

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------
Write-Host "`nExporting reports..." -ForegroundColor Yellow

if ($Format -eq 'CSV') {
    $allUsersFile      = Join-Path $OutputPath "ADReport_AllUsers_$timestamp.csv"
    $disabledFile      = Join-Path $OutputPath "ADReport_Disabled_$timestamp.csv"
    $lockedFile        = Join-Path $OutputPath "ADReport_Locked_$timestamp.csv"
    $staleFile         = Join-Path $OutputPath "ADReport_Stale_$timestamp.csv"
    $expiredPwdFile    = Join-Path $OutputPath "ADReport_ExpiredPasswords_$timestamp.csv"

    $userReport      | Export-Csv -Path $allUsersFile   -NoTypeInformation -Encoding UTF8
    $disabledAccounts | Export-Csv -Path $disabledFile   -NoTypeInformation -Encoding UTF8
    $lockedAccounts  | Export-Csv -Path $lockedFile      -NoTypeInformation -Encoding UTF8
    $staleAccounts   | Export-Csv -Path $staleFile       -NoTypeInformation -Encoding UTF8
    $expiredPasswords | Export-Csv -Path $expiredPwdFile  -NoTypeInformation -Encoding UTF8

    $reportFiles = @($allUsersFile, $disabledFile, $lockedFile, $staleFile, $expiredPwdFile)
}
else {
    $htmlFile = Join-Path $OutputPath "ADReport_$timestamp.html"
    $metaInfo = "<div class='meta'>Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Domain: $env:USERDNSDOMAIN | Total Users: $($allUsers.Count)</div>"

    $htmlBody = @"
<h1>Active Directory Report</h1>
$metaInfo

<h2>All Users ($($userReport.Count))</h2>
$($userReport | ConvertTo-Html -Fragment)

<h2>Disabled Accounts ($($disabledAccounts.Count))</h2>
$(if ($disabledAccounts.Count -gt 0) { $disabledAccounts | Select-Object DisplayName, SamAccountName, Department, LastLogon, Created | ConvertTo-Html -Fragment } else { '<p class="ok">No disabled accounts found.</p>' })

<h2>Locked Accounts ($($lockedAccounts.Count))</h2>
$(if ($lockedAccounts.Count -gt 0) { $lockedAccounts | Select-Object DisplayName, SamAccountName, Department, LastLogon | ConvertTo-Html -Fragment } else { '<p class="ok">No locked accounts found.</p>' })

<h2>Stale Accounts - No Logon in $StaleDays+ Days ($($staleAccounts.Count))</h2>
$(if ($staleAccounts.Count -gt 0) { $staleAccounts | Select-Object DisplayName, SamAccountName, Department, LastLogon, Created | ConvertTo-Html -Fragment } else { '<p class="ok">No stale accounts found.</p>' })

<h2>Expired Passwords ($($expiredPasswords.Count))</h2>
$(if ($expiredPasswords.Count -gt 0) { $expiredPasswords | Select-Object DisplayName, SamAccountName, Department, PasswordLastSet, PasswordAgeDays | ConvertTo-Html -Fragment } else { '<p class="ok">No expired passwords found.</p>' })
"@

    ConvertTo-Html -Head $htmlHead -Body $htmlBody -Title "AD Report - $timestamp" |
        Out-File -FilePath $htmlFile -Encoding UTF8

    $reportFiles = @($htmlFile)
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host "`n=== Report Complete ===" -ForegroundColor Green
foreach ($file in $reportFiles) {
    Write-Host "  $file"
}
Write-Host ""

if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
    Write-Log -Message "AD report generated: $($reportFiles.Count) file(s) in $OutputPath ($Format format)"
}
