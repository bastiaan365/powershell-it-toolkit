<#
.SYNOPSIS
    Manages Intune compliance policies and checks device compliance status.

.DESCRIPTION
    Helper script for Intune policy management via Microsoft Graph API:
    - List all compliance policies in the tenant
    - View details of a specific policy
    - Check device compliance status
    - Assign a compliance policy to a group

    Uses the Microsoft.Graph PowerShell module for API access.

.PARAMETER Action
    The operation to perform: List, Get, CheckCompliance, or Assign.

.PARAMETER PolicyId
    ID of a specific compliance policy (required for Get and Assign actions).

.PARAMETER GroupId
    Entra ID group ID to assign the policy to (required for Assign action).

.PARAMETER DeviceId
    Specific device ID to check compliance for. If omitted, checks all devices.

.PARAMETER ExportPath
    Optional path to export results as CSV.

.EXAMPLE
    .\Set-IntunePolicy.ps1 -Action List
    List all compliance policies in the tenant.

.EXAMPLE
    .\Set-IntunePolicy.ps1 -Action CheckCompliance
    Check compliance status for all managed devices.

.EXAMPLE
    .\Set-IntunePolicy.ps1 -Action Assign -PolicyId "abc-123" -GroupId "def-456" -WhatIf
    Preview assigning a policy to a group without making changes.

.EXAMPLE
    .\Set-IntunePolicy.ps1 -Action CheckCompliance -ExportPath "C:\Reports\compliance.csv"

.NOTES
    Author:  Bastiaan Rusch
    Version: 1.0.0
    Requires: Microsoft.Graph.DeviceManagement module
#>

#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)]
    [ValidateSet('List', 'Get', 'CheckCompliance', 'Assign')]
    [string]$Action,

    [Parameter()]
    [string]$PolicyId,

    [Parameter()]
    [string]$GroupId,

    [Parameter()]
    [string]$DeviceId,

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
# Validate parameters
# ---------------------------------------------------------------------------
if ($Action -eq 'Get' -and -not $PolicyId) {
    throw "The -PolicyId parameter is required when using -Action Get."
}
if ($Action -eq 'Assign' -and (-not $PolicyId -or -not $GroupId)) {
    throw "Both -PolicyId and -GroupId parameters are required when using -Action Assign."
}

# ---------------------------------------------------------------------------
# Connect to Microsoft Graph
# ---------------------------------------------------------------------------
function Connect-GraphIfNeeded {
    [CmdletBinding()]
    param()

    $context = Get-MgContext -ErrorAction SilentlyContinue
    if (-not $context) {
        Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Yellow
        try {
            $config = Get-Config -ErrorAction SilentlyContinue
            $scopes = $config.M365.GraphScopes
        }
        catch {
            $scopes = @(
                'DeviceManagementConfiguration.ReadWrite.All',
                'DeviceManagementManagedDevices.Read.All'
            )
        }
        Connect-MgGraph -Scopes $scopes -NoWelcome
        Write-Host "Connected to Microsoft Graph" -ForegroundColor Green
    }
    else {
        Write-Verbose "Already connected to Microsoft Graph as $($context.Account)"
    }
}

# ---------------------------------------------------------------------------
# Action: List compliance policies
# ---------------------------------------------------------------------------
function Get-CompliancePolicies {
    [CmdletBinding()]
    param()

    Write-Host "`n=== Intune Compliance Policies ===" -ForegroundColor Cyan

    $uri = 'https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies'
    $response = Invoke-MgGraphRequest -Method GET -Uri $uri

    $policies = $response.value | ForEach-Object {
        [PSCustomObject]@{
            Id                = $_.id
            DisplayName       = $_.displayName
            Description       = $_.description
            Platform          = $_.'@odata.type' -replace '#microsoft.graph.', '' -replace 'CompliancePolicy', ''
            Created           = if ($_.createdDateTime) { ([datetime]$_.createdDateTime).ToString('yyyy-MM-dd') } else { 'N/A' }
            LastModified      = if ($_.lastModifiedDateTime) { ([datetime]$_.lastModifiedDateTime).ToString('yyyy-MM-dd') } else { 'N/A' }
        }
    }

    $policies | Format-Table -AutoSize
    Write-Host "Total policies: $($policies.Count)" -ForegroundColor Green

    return $policies
}

# ---------------------------------------------------------------------------
# Action: Get policy details
# ---------------------------------------------------------------------------
function Get-PolicyDetails {
    [CmdletBinding()]
    param([string]$Id)

    Write-Host "`n=== Policy Details ===" -ForegroundColor Cyan

    $uri = "https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies/$Id"
    $policy = Invoke-MgGraphRequest -Method GET -Uri $uri

    Write-Host "Name:          $($policy.displayName)"
    Write-Host "Description:   $($policy.description)"
    Write-Host "Platform:      $($policy.'@odata.type' -replace '#microsoft.graph.', '')"
    Write-Host "Created:       $($policy.createdDateTime)"
    Write-Host "Last Modified: $($policy.lastModifiedDateTime)"

    # Get assignments
    $assignUri = "https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies/$Id/assignments"
    $assignments = Invoke-MgGraphRequest -Method GET -Uri $assignUri

    Write-Host "`nAssignments:" -ForegroundColor Yellow
    if ($assignments.value.Count -eq 0) {
        Write-Host "  No assignments found." -ForegroundColor DarkGray
    }
    else {
        foreach ($assignment in $assignments.value) {
            $target = $assignment.target
            $targetType = $target.'@odata.type' -replace '#microsoft.graph.', ''
            $groupId = $target.groupId
            Write-Host "  Type: $targetType | Group: $groupId"
        }
    }

    # Get device statuses
    $statusUri = "https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies/$Id/deviceStatuses"
    $statuses = Invoke-MgGraphRequest -Method GET -Uri $statusUri

    Write-Host "`nDevice Status Summary:" -ForegroundColor Yellow
    $statusGroups = $statuses.value | Group-Object -Property status
    foreach ($group in $statusGroups) {
        $color = switch ($group.Name) {
            'compliant'    { 'Green' }
            'nonCompliant' { 'Red' }
            'unknown'      { 'Yellow' }
            default        { 'White' }
        }
        Write-Host "  $($group.Name): $($group.Count)" -ForegroundColor $color
    }
}

# ---------------------------------------------------------------------------
# Action: Check device compliance
# ---------------------------------------------------------------------------
function Get-DeviceCompliance {
    [CmdletBinding()]
    param(
        [string]$SpecificDeviceId,
        [string]$Export
    )

    Write-Host "`n=== Device Compliance Status ===" -ForegroundColor Cyan

    $uri = if ($SpecificDeviceId) {
        "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$SpecificDeviceId"
    }
    else {
        'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices'
    }

    $response = Invoke-MgGraphRequest -Method GET -Uri $uri

    $devices = if ($SpecificDeviceId) {
        @($response)
    }
    else {
        $response.value
    }

    $report = $devices | ForEach-Object {
        [PSCustomObject]@{
            DeviceName       = $_.deviceName
            UserDisplayName  = $_.userDisplayName
            UserPrincipal    = $_.userPrincipalName
            OS               = $_.operatingSystem
            OSVersion        = $_.osVersion
            ComplianceState  = $_.complianceState
            LastSync         = if ($_.lastSyncDateTime) { ([datetime]$_.lastSyncDateTime).ToString('yyyy-MM-dd HH:mm') } else { 'Never' }
            IsEncrypted      = $_.isEncrypted
            IsSupervised     = $_.isSupervised
            Model            = $_.model
            Manufacturer     = $_.manufacturer
        }
    }

    # Display summary
    $compliant    = ($report | Where-Object ComplianceState -eq 'compliant').Count
    $nonCompliant = ($report | Where-Object ComplianceState -eq 'noncompliant').Count
    $unknown      = ($report | Where-Object ComplianceState -notin 'compliant', 'noncompliant').Count

    Write-Host "  Compliant:     $compliant" -ForegroundColor Green
    Write-Host "  Non-Compliant: $nonCompliant" -ForegroundColor $(if ($nonCompliant -gt 0) { 'Red' } else { 'Green' })
    Write-Host "  Unknown/Other: $unknown" -ForegroundColor $(if ($unknown -gt 0) { 'Yellow' } else { 'Green' })
    Write-Host "  Total Devices: $($report.Count)`n"

    # Show non-compliant devices
    $ncDevices = $report | Where-Object ComplianceState -eq 'noncompliant'
    if ($ncDevices.Count -gt 0) {
        Write-Host "Non-Compliant Devices:" -ForegroundColor Red
        $ncDevices | Format-Table DeviceName, UserDisplayName, OS, OSVersion, LastSync -AutoSize
    }

    # Export if requested
    if ($Export) {
        $exportDir = Split-Path -Parent $Export
        if ($exportDir -and -not (Test-Path $exportDir)) {
            New-Item -Path $exportDir -ItemType Directory -Force | Out-Null
        }
        $report | Export-Csv -Path $Export -NoTypeInformation -Encoding UTF8
        Write-Host "Report exported to: $Export" -ForegroundColor Green
    }

    return $report
}

# ---------------------------------------------------------------------------
# Action: Assign policy to group
# ---------------------------------------------------------------------------
function Set-PolicyAssignment {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Policy,
        [string]$Group
    )

    if ($PSCmdlet.ShouldProcess("Policy $Policy -> Group $Group", 'Assign compliance policy')) {
        Write-Host "`n=== Assigning Compliance Policy ===" -ForegroundColor Cyan

        $uri = "https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies/$Policy/assign"

        $body = @{
            assignments = @(
                @{
                    target = @{
                        '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
                        groupId       = $Group
                    }
                }
            )
        } | ConvertTo-Json -Depth 10

        try {
            Invoke-MgGraphRequest -Method POST -Uri $uri -Body $body -ContentType 'application/json'
            Write-Host "Policy assigned successfully" -ForegroundColor Green
            Write-Log -Message "Intune policy $Policy assigned to group $Group"
        }
        catch {
            Write-Error "Failed to assign policy: $($_.Exception.Message)"
            Write-Log -Message "Failed to assign Intune policy $Policy to group $Group - $_" -Level Error
        }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Connect-GraphIfNeeded

switch ($Action) {
    'List' {
        $result = Get-CompliancePolicies
        if ($ExportPath) {
            $result | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
            Write-Host "Exported to: $ExportPath" -ForegroundColor Green
        }
    }
    'Get' {
        Get-PolicyDetails -Id $PolicyId
    }
    'CheckCompliance' {
        Get-DeviceCompliance -SpecificDeviceId $DeviceId -Export $ExportPath
    }
    'Assign' {
        Set-PolicyAssignment -Policy $PolicyId -Group $GroupId
    }
}
