<#
.SYNOPSIS
    Performs a comprehensive system health check and reports key metrics.

.DESCRIPTION
    Collects and displays system health information including:
    - CPU usage (current and average)
    - RAM usage and availability
    - Disk space utilization for all fixed drives
    - System uptime
    - Pending Windows updates
    - Certificate expiration status
    - Critical service status

    Results can be displayed as a formatted table or exported to CSV.

.PARAMETER ComputerName
    Target computer(s) to check. Defaults to the local machine.

.PARAMETER ExportPath
    Path to export results as CSV. If omitted, results display in the console.

.PARAMETER CertWarningDays
    Number of days before certificate expiry to flag as warning. Defaults to 30.

.EXAMPLE
    .\Get-SystemHealth.ps1
    Run a health check on the local machine with console output.

.EXAMPLE
    .\Get-SystemHealth.ps1 -ComputerName "SERVER01","SERVER02" -ExportPath "C:\Reports\health.csv"
    Check multiple servers and export to CSV.

.EXAMPLE
    .\Get-SystemHealth.ps1 -CertWarningDays 60 -Verbose
    Check local machine with 60-day certificate warning threshold.

.NOTES
    Author:  Bastiaan Rusch
    Version: 1.0.0
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [Alias('CN', 'Server')]
    [string[]]$ComputerName = @($env:COMPUTERNAME),

    [ValidateScript({
        $dir = Split-Path -Parent $_
        if ($dir -and -not (Test-Path $dir)) {
            throw "Directory does not exist: $dir"
        }
        return $true
    })]
    [string]$ExportPath,

    [ValidateRange(1, 365)]
    [int]$CertWarningDays = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# Import shared module
$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'modules\ITToolkit.psm1'
if (Test-Path $modulePath) {
    Import-Module $modulePath -Force
}

# Load config for thresholds
try {
    $config = Get-Config -ErrorAction SilentlyContinue
    if (-not $PSBoundParameters.ContainsKey('CertWarningDays')) {
        $CertWarningDays = $config.SystemHealth.CertExpiryWarningDays
    }
    $monitoredServices = $config.SystemHealth.MonitoredServices
    $diskWarningPct    = $config.SystemHealth.DiskSpaceWarningPercent
    $diskCriticalPct   = $config.SystemHealth.DiskSpaceCriticalPercent
}
catch {
    $monitoredServices = @('Spooler', 'W32Time', 'WinRM', 'BITS', 'wuauserv')
    $diskWarningPct    = 20
    $diskCriticalPct   = 10
}

# ---------------------------------------------------------------------------
# Collect health data
# ---------------------------------------------------------------------------
$allResults = [System.Collections.ArrayList]::new()

foreach ($computer in $ComputerName) {
    Write-Host "`n=== System Health: $computer ===" -ForegroundColor Cyan

    $isLocal = $computer -eq $env:COMPUTERNAME -or $computer -eq 'localhost'

    try {
        # --- CPU ---
        Write-Verbose "Checking CPU usage on $computer..."
        $cpuLoad = if ($isLocal) {
            (Get-CimInstance -ClassName Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
        }
        else {
            (Get-CimInstance -ClassName Win32_Processor -ComputerName $computer |
                Measure-Object -Property LoadPercentage -Average).Average
        }

        # --- Memory ---
        Write-Verbose "Checking memory on $computer..."
        $os = if ($isLocal) {
            Get-CimInstance -ClassName Win32_OperatingSystem
        }
        else {
            Get-CimInstance -ClassName Win32_OperatingSystem -ComputerName $computer
        }

        $totalRAM   = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
        $freeRAM    = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
        $usedRAMPct = [math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100, 1)

        # --- Uptime ---
        $uptime    = (Get-Date) - $os.LastBootUpTime
        $uptimeStr = "{0}d {1}h {2}m" -f $uptime.Days, $uptime.Hours, $uptime.Minutes

        # --- Disk Space ---
        Write-Verbose "Checking disk space on $computer..."
        $disks = if ($isLocal) {
            Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3"
        }
        else {
            Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" -ComputerName $computer
        }

        $diskResults = foreach ($disk in $disks) {
            $freePercent = [math]::Round(($disk.FreeSpace / $disk.Size) * 100, 1)
            $status = if ($freePercent -le $diskCriticalPct) { 'CRITICAL' }
                      elseif ($freePercent -le $diskWarningPct) { 'WARNING' }
                      else { 'OK' }

            [PSCustomObject]@{
                Drive       = $disk.DeviceID
                SizeGB      = [math]::Round($disk.Size / 1GB, 2)
                FreeGB      = [math]::Round($disk.FreeSpace / 1GB, 2)
                FreePercent = $freePercent
                Status      = $status
            }
        }

        # --- Pending Updates ---
        Write-Verbose "Checking pending updates on $computer..."
        $pendingUpdates = 0
        try {
            $updateSession  = New-Object -ComObject Microsoft.Update.Session
            $updateSearcher = $updateSession.CreateUpdateSearcher()
            $searchResult   = $updateSearcher.Search("IsInstalled=0 AND IsHidden=0")
            $pendingUpdates = $searchResult.Updates.Count
        }
        catch {
            Write-Verbose "Could not check Windows Updates: $($_.Exception.Message)"
            $pendingUpdates = -1  # Unknown
        }

        # --- Certificate Expiration ---
        Write-Verbose "Checking certificates on $computer..."
        $expiringCerts = @()
        try {
            $certs = Get-ChildItem -Path Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
                Where-Object { $_.NotAfter -lt (Get-Date).AddDays($CertWarningDays) -and $_.NotAfter -gt (Get-Date) }
            $expiringCerts = foreach ($cert in $certs) {
                [PSCustomObject]@{
                    Subject    = $cert.Subject
                    Thumbprint = $cert.Thumbprint.Substring(0, 8) + '...'
                    ExpiresOn  = $cert.NotAfter.ToString('yyyy-MM-dd')
                    DaysLeft   = [math]::Ceiling(($cert.NotAfter - (Get-Date)).TotalDays)
                }
            }
        }
        catch {
            Write-Verbose "Could not check certificates: $($_.Exception.Message)"
        }

        $expiredCerts = @()
        try {
            $expiredCerts = Get-ChildItem -Path Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
                Where-Object { $_.NotAfter -lt (Get-Date) } |
                ForEach-Object {
                    [PSCustomObject]@{
                        Subject    = $_.Subject
                        Thumbprint = $_.Thumbprint.Substring(0, 8) + '...'
                        ExpiredOn  = $_.NotAfter.ToString('yyyy-MM-dd')
                    }
                }
        }
        catch { }

        # --- Service Status ---
        Write-Verbose "Checking service status on $computer..."
        $serviceResults = foreach ($svc in $monitoredServices) {
            try {
                $service = if ($isLocal) {
                    Get-Service -Name $svc -ErrorAction Stop
                }
                else {
                    Get-Service -Name $svc -ComputerName $computer -ErrorAction Stop
                }

                [PSCustomObject]@{
                    Name   = $service.DisplayName
                    Status = $service.Status.ToString()
                    Alert  = if ($service.Status -ne 'Running') { 'NOT RUNNING' } else { 'OK' }
                }
            }
            catch {
                [PSCustomObject]@{
                    Name   = $svc
                    Status = 'Not Found'
                    Alert  = 'MISSING'
                }
            }
        }

        # --- Display Results ---
        Write-Host "`n  CPU Usage:       $cpuLoad %" -ForegroundColor $(if ($cpuLoad -gt 90) { 'Red' } elseif ($cpuLoad -gt 70) { 'Yellow' } else { 'Green' })
        Write-Host "  RAM:             $usedRAMPct% used ($freeRAM GB free / $totalRAM GB total)" -ForegroundColor $(if ($usedRAMPct -gt 90) { 'Red' } elseif ($usedRAMPct -gt 80) { 'Yellow' } else { 'Green' })
        Write-Host "  Uptime:          $uptimeStr"
        Write-Host "  Pending Updates: $(if ($pendingUpdates -ge 0) { $pendingUpdates } else { 'Unknown' })" -ForegroundColor $(if ($pendingUpdates -gt 10) { 'Red' } elseif ($pendingUpdates -gt 0) { 'Yellow' } else { 'Green' })

        Write-Host "`n  Disk Space:" -ForegroundColor White
        $diskResults | Format-Table -AutoSize | Out-String | Write-Host

        if ($expiringCerts.Count -gt 0) {
            Write-Host "  Expiring Certificates (within $CertWarningDays days):" -ForegroundColor Yellow
            $expiringCerts | Format-Table -AutoSize | Out-String | Write-Host
        }

        if ($expiredCerts.Count -gt 0) {
            Write-Host "  Expired Certificates:" -ForegroundColor Red
            $expiredCerts | Format-Table -AutoSize | Out-String | Write-Host
        }

        Write-Host "  Services:" -ForegroundColor White
        $serviceResults | Format-Table -AutoSize | Out-String | Write-Host

        # --- Aggregate for CSV export ---
        [void]$allResults.Add([PSCustomObject]@{
            ComputerName   = $computer
            Timestamp      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            CPUPercent     = $cpuLoad
            RAMPercent     = $usedRAMPct
            RAMFreeGB      = $freeRAM
            RAMTotalGB     = $totalRAM
            Uptime         = $uptimeStr
            PendingUpdates = $pendingUpdates
            ExpiringCerts  = $expiringCerts.Count
            ExpiredCerts   = $expiredCerts.Count
            DiskAlerts     = ($diskResults | Where-Object Status -ne 'OK').Count
            ServiceAlerts  = ($serviceResults | Where-Object Alert -ne 'OK').Count
        })
    }
    catch {
        Write-Warning "Failed to collect health data from $computer : $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------
if ($ExportPath -and $allResults.Count -gt 0) {
    $allResults | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
    Write-Host "`nResults exported to: $ExportPath" -ForegroundColor Green
}

if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
    Write-Log -Message "System health check completed for $($ComputerName -join ', ')"
}
