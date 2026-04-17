<#
.SYNOPSIS
    Compares and synchronizes group membership between Active Directory and Microsoft 365.

.DESCRIPTION
    Identifies discrepancies between on-premises AD groups and their M365 counterparts:
    - Members present in AD but missing from M365
    - Members present in M365 but missing from AD
    - Groups that exist in one directory but not the other

    Can optionally synchronize membership to resolve discrepancies.
    Uses the Microsoft.Graph PowerShell module for M365 operations.

.PARAMETER GroupFilter
    Wildcard filter for group names to process. Defaults to '*' (all groups).

.PARAMETER ADGroupPrefix
    Prefix used to identify AD groups that should have M365 counterparts.
    Defaults to 'M365-'.

.PARAMETER SyncDirection
    Direction of synchronization: ADtoM365, M365toAD, or ReportOnly.
    Defaults to ReportOnly.

.PARAMETER ExportPath
    Path to export the discrepancy report as CSV.

.EXAMPLE
    .\Sync-M365Groups.ps1 -SyncDirection ReportOnly
    Generate a report of all discrepancies without making changes.

.EXAMPLE
    .\Sync-M365Groups.ps1 -ADGroupPrefix "M365-" -SyncDirection ADtoM365 -WhatIf
    Preview syncing AD group membership to M365 for groups prefixed with 'M365-'.

.EXAMPLE
    .\Sync-M365Groups.ps1 -GroupFilter "M365-Finance*" -ExportPath "C:\Reports\sync.csv"
    Report on Finance-related groups and export to CSV.

.NOTES
    Author:  Bastiaan Rusch
    Version: 1.0.0
    Requires: ActiveDirectory module, Microsoft.Graph module
#>

#Requires -Version 5.1
#Requires -Modules ActiveDirectory, Microsoft.Graph.Authentication

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$GroupFilter = '*',

    [string]$ADGroupPrefix = 'M365-',

    [ValidateSet('ADtoM365', 'M365toAD', 'ReportOnly')]
    [string]$SyncDirection = 'ReportOnly',

    [string]$ExportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Import shared module
$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'modules/ITToolkit'
if (Test-Path $modulePath) {
    Import-Module $modulePath -Force
}

# ---------------------------------------------------------------------------
# Connect to Microsoft Graph
# ---------------------------------------------------------------------------
$context = Get-MgContext -ErrorAction SilentlyContinue
if (-not $context) {
    Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Yellow
    Connect-MgGraph -Scopes 'Group.ReadWrite.All', 'GroupMember.ReadWrite.All', 'User.Read.All' -NoWelcome
    Write-Host "Connected to Microsoft Graph" -ForegroundColor Green
}

Write-Host "`n=== M365 Group Sync ===" -ForegroundColor Cyan
Write-Host "Filter:    $GroupFilter"
Write-Host "Prefix:    $ADGroupPrefix"
Write-Host "Direction: $SyncDirection"
Write-Host ""

# ---------------------------------------------------------------------------
# Collect AD groups
# ---------------------------------------------------------------------------
Write-Host "Collecting AD groups..." -ForegroundColor Yellow
$adGroups = Get-ADGroup -Filter "Name -like '$ADGroupPrefix$GroupFilter'" -Properties Members, Description |
    Sort-Object Name

Write-Host "  Found $($adGroups.Count) AD groups matching filter" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Process each group
# ---------------------------------------------------------------------------
$discrepancies = [System.Collections.ArrayList]::new()
$summary = @{
    GroupsProcessed    = 0
    MissingInM365      = 0
    MissingInAD        = 0
    MembersAdded       = 0
    MembersRemoved     = 0
    Errors             = 0
}

foreach ($adGroup in $adGroups) {
    $summary.GroupsProcessed++
    $groupName = $adGroup.Name
    $m365GroupName = $groupName -replace "^$([regex]::Escape($ADGroupPrefix))", ''

    Write-Host "`nProcessing: $groupName -> $m365GroupName" -ForegroundColor Yellow

    # --- Get AD members (as UPNs) ---
    $adMembers = @()
    try {
        $adMemberObjects = Get-ADGroupMember -Identity $adGroup.DistinguishedName -Recursive |
            Where-Object { $_.objectClass -eq 'user' }

        $adMembers = foreach ($member in $adMemberObjects) {
            $user = Get-ADUser -Identity $member.SamAccountName -Properties UserPrincipalName
            $user.UserPrincipalName
        }
        $adMembers = @($adMembers | Where-Object { $_ })
    }
    catch {
        Write-Warning "  Could not enumerate AD members for $groupName : $($_.Exception.Message)"
        $summary.Errors++
        continue
    }

    # --- Find matching M365 group ---
    $m365Group = $null
    try {
        $uri = "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$m365GroupName'"
        $response = Invoke-MgGraphRequest -Method GET -Uri $uri
        $m365Group = $response.value | Select-Object -First 1
    }
    catch {
        Write-Warning "  Could not query M365 for group '$m365GroupName': $($_.Exception.Message)"
        $summary.Errors++
        continue
    }

    if (-not $m365Group) {
        Write-Host "  M365 group '$m365GroupName' not found - skipping" -ForegroundColor DarkGray
        [void]$discrepancies.Add([PSCustomObject]@{
            GroupName    = $groupName
            M365Group    = $m365GroupName
            Type         = 'GroupMissingInM365'
            User         = ''
            Direction    = 'N/A'
            ActionTaken  = 'None'
        })
        continue
    }

    # --- Get M365 members ---
    $m365Members = @()
    try {
        $memberUri = "https://graph.microsoft.com/v1.0/groups/$($m365Group.id)/members"
        $memberResponse = Invoke-MgGraphRequest -Method GET -Uri $memberUri

        $m365Members = @($memberResponse.value |
            Where-Object { $_.'@odata.type' -eq '#microsoft.graph.user' } |
            ForEach-Object { $_.userPrincipalName })
    }
    catch {
        Write-Warning "  Could not get M365 members: $($_.Exception.Message)"
        $summary.Errors++
        continue
    }

    Write-Host "  AD members: $($adMembers.Count) | M365 members: $($m365Members.Count)"

    # --- Compare ---
    $inADNotM365 = $adMembers | Where-Object { $_ -notin $m365Members }
    $inM365NotAD = $m365Members | Where-Object { $_ -notin $adMembers }

    foreach ($user in $inADNotM365) {
        $actionTaken = 'None'
        $summary.MissingInM365++

        if ($SyncDirection -eq 'ADtoM365') {
            if ($PSCmdlet.ShouldProcess("$user -> $m365GroupName", 'Add to M365 group')) {
                try {
                    $mgUser = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/users/$user"
                    $addBody = @{
                        '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$($mgUser.id)"
                    } | ConvertTo-Json
                    Invoke-MgGraphRequest -Method POST `
                        -Uri "https://graph.microsoft.com/v1.0/groups/$($m365Group.id)/members/`$ref" `
                        -Body $addBody -ContentType 'application/json'
                    $actionTaken = 'Added to M365'
                    $summary.MembersAdded++
                    Write-Host "    + Added to M365: $user" -ForegroundColor Green
                }
                catch {
                    $actionTaken = "Error: $($_.Exception.Message)"
                    $summary.Errors++
                    Write-Warning "    Could not add $user to M365 group: $($_.Exception.Message)"
                }
            }
        }

        [void]$discrepancies.Add([PSCustomObject]@{
            GroupName   = $groupName
            M365Group   = $m365GroupName
            Type        = 'MemberMissingInM365'
            User        = $user
            Direction   = 'AD -> M365'
            ActionTaken = $actionTaken
        })
    }

    foreach ($user in $inM365NotAD) {
        $actionTaken = 'None'
        $summary.MissingInAD++

        if ($SyncDirection -eq 'M365toAD') {
            if ($PSCmdlet.ShouldProcess("$user -> $groupName", 'Add to AD group')) {
                try {
                    $adUser = Get-ADUser -Filter "UserPrincipalName -eq '$user'" -ErrorAction Stop
                    Add-ADGroupMember -Identity $adGroup.DistinguishedName -Members $adUser -ErrorAction Stop
                    $actionTaken = 'Added to AD'
                    $summary.MembersAdded++
                    Write-Host "    + Added to AD: $user" -ForegroundColor Green
                }
                catch {
                    $actionTaken = "Error: $($_.Exception.Message)"
                    $summary.Errors++
                    Write-Warning "    Could not add $user to AD group: $($_.Exception.Message)"
                }
            }
        }

        [void]$discrepancies.Add([PSCustomObject]@{
            GroupName   = $groupName
            M365Group   = $m365GroupName
            Type        = 'MemberMissingInAD'
            User        = $user
            Direction   = 'M365 -> AD'
            ActionTaken = $actionTaken
        })
    }

    if ($inADNotM365.Count -eq 0 -and $inM365NotAD.Count -eq 0) {
        Write-Host "  Groups are in sync" -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host "`n=== Sync Summary ===" -ForegroundColor Cyan
Write-Host "Groups Processed:       $($summary.GroupsProcessed)"
Write-Host "Members Missing in M365: $($summary.MissingInM365)" -ForegroundColor $(if ($summary.MissingInM365 -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "Members Missing in AD:   $($summary.MissingInAD)" -ForegroundColor $(if ($summary.MissingInAD -gt 0) { 'Yellow' } else { 'Green' })
if ($SyncDirection -ne 'ReportOnly') {
    Write-Host "Members Added:           $($summary.MembersAdded)" -ForegroundColor Green
}
Write-Host "Errors:                  $($summary.Errors)" -ForegroundColor $(if ($summary.Errors -gt 0) { 'Red' } else { 'Green' })
Write-Host "Total Discrepancies:     $($discrepancies.Count)"

if ($WhatIfPreference) {
    Write-Host "`n(WhatIf mode - no changes were made)" -ForegroundColor DarkYellow
}

# Export
if ($ExportPath -and $discrepancies.Count -gt 0) {
    $exportDir = Split-Path -Parent $ExportPath
    if ($exportDir -and -not (Test-Path $exportDir)) {
        New-Item -Path $exportDir -ItemType Directory -Force | Out-Null
    }
    $discrepancies | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
    Write-Host "`nReport exported to: $ExportPath" -ForegroundColor Green
}

if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
    Write-Log -Message "M365 Group Sync completed. Direction: $SyncDirection, Discrepancies: $($discrepancies.Count)"
}

Write-Host ""
