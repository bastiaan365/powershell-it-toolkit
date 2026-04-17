<#
.SYNOPSIS
    Performs comprehensive network diagnostics and generates a connectivity report.

.DESCRIPTION
    Runs a suite of network diagnostic tests including:
    - DNS resolution for internal and external hosts
    - Default gateway reachability
    - Internet connectivity (HTTP/HTTPS)
    - Port connectivity to common services (LDAP, SMTP, etc.)
    - Trace route to a target host
    - Network adapter and IP configuration summary

    Results are displayed in the console and optionally exported to a file.

.PARAMETER TestHosts
    List of hostnames to test DNS resolution and connectivity against.
    Defaults to common public DNS and Microsoft endpoints.

.PARAMETER TracerouteTarget
    Host to trace route to. Defaults to 'www.microsoft.com'.

.PARAMETER MaxHops
    Maximum hops for traceroute. Defaults to 15.

.PARAMETER ExportPath
    Path to export the full diagnostic report as a text file.

.PARAMETER SkipTraceroute
    Skip the traceroute test (can be slow).

.EXAMPLE
    .\Test-NetworkDiag.ps1
    Run all network diagnostics with default settings.

.EXAMPLE
    .\Test-NetworkDiag.ps1 -ExportPath "C:\Reports\network.txt"
    Run diagnostics and save results to a file.

.EXAMPLE
    .\Test-NetworkDiag.ps1 -TestHosts "dc01.contoso.com","exchange.contoso.com" -SkipTraceroute

.NOTES
    Author:  Bastiaan Rusch
    Version: 1.0.0
#>

#Requires -Version 5.1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingComputerNameHardcoded', '',
    Justification='8.8.8.8 (Google Public DNS) is used as a sentinel public IP for internet-reachability checks; it leaks no private information about the system or network.')]
[CmdletBinding()]
param(
    [string[]]$TestHosts = @('www.microsoft.com', 'www.google.com', 'dns.google'),

    [string]$TracerouteTarget = 'www.microsoft.com',

    [ValidateRange(1, 30)]
    [int]$MaxHops = 15,

    [string]$ExportPath,

    [switch]$SkipTraceroute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# Import shared module
$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'modules/ITToolkit'
if (Test-Path $modulePath) {
    Import-Module $modulePath -Force
}

# Load config for custom test targets
try {
    $config = Get-Config -ErrorAction SilentlyContinue
    $dnsServers  = $config.NetworkDiagnostics.DnsServers
    $testUrls    = $config.NetworkDiagnostics.TestUrls
    $commonPorts = $config.NetworkDiagnostics.CommonPorts
}
catch {
    $dnsServers  = @('8.8.8.8', '1.1.1.1')
    $testUrls    = @('https://www.microsoft.com', 'https://portal.azure.com')
    $commonPorts = @(
        [PSCustomObject]@{ Host = 'smtp.office365.com';  Port = 587; Description = 'M365 SMTP' }
        [PSCustomObject]@{ Host = 'outlook.office365.com'; Port = 443; Description = 'M365 Outlook' }
    )
}

# Report collector
$report = [System.Text.StringBuilder]::new()

function Add-ReportLine {
    param([string]$Line, [string]$Color = 'White')
    [void]$report.AppendLine($Line)
    Write-Host $Line -ForegroundColor $Color
}

function Add-ReportBlank {
    [void]$report.AppendLine('')
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
$divider = '=' * 60

Add-ReportLine $divider 'Cyan'
Add-ReportLine '  Network Diagnostics Report' 'Cyan'
Add-ReportLine $divider 'Cyan'
Add-ReportLine "  Computer:  $env:COMPUTERNAME"
Add-ReportLine "  User:      $env:USERNAME"
Add-ReportLine "  Date:      $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Add-ReportLine $divider 'Cyan'
Add-ReportBlank

# ---------------------------------------------------------------------------
# 1. Network Adapter Summary
# ---------------------------------------------------------------------------
Add-ReportLine '[1/6] Network Adapter Configuration' 'Yellow'
Add-ReportLine ('-' * 40)

try {
    $adapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up'
    if (-not $adapters) {
        $adapters = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration |
            Where-Object { $_.IPEnabled -eq $true }

        foreach ($adapter in $adapters) {
            Add-ReportLine "  Adapter:   $($adapter.Description)"
            Add-ReportLine "  IP:        $($adapter.IPAddress -join ', ')"
            Add-ReportLine "  Subnet:    $($adapter.IPSubnet -join ', ')"
            Add-ReportLine "  Gateway:   $($adapter.DefaultIPGateway -join ', ')"
            Add-ReportLine "  DNS:       $($adapter.DNSServerSearchOrder -join ', ')"
            Add-ReportLine "  DHCP:      $($adapter.DHCPEnabled)"
            Add-ReportBlank
        }
    }
    else {
        foreach ($adapter in $adapters) {
            $ipConfig = Get-NetIPConfiguration -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue
            Add-ReportLine "  Adapter:   $($adapter.Name) ($($adapter.InterfaceDescription))"
            Add-ReportLine "  Status:    $($adapter.Status)"
            Add-ReportLine "  Speed:     $([math]::Round($adapter.LinkSpeed / 1e6, 0)) Mbps" -ErrorAction SilentlyContinue
            if ($ipConfig.IPv4Address) {
                Add-ReportLine "  IPv4:      $($ipConfig.IPv4Address.IPAddress)"
            }
            if ($ipConfig.IPv4DefaultGateway) {
                Add-ReportLine "  Gateway:   $($ipConfig.IPv4DefaultGateway.NextHop)"
            }
            if ($ipConfig.DNSServer) {
                Add-ReportLine "  DNS:       $($ipConfig.DNSServer.ServerAddresses -join ', ')"
            }
            Add-ReportBlank
        }
    }
}
catch {
    Add-ReportLine "  Could not retrieve adapter info: $($_.Exception.Message)" 'Red'
    Add-ReportBlank
}

# ---------------------------------------------------------------------------
# 2. DNS Resolution
# ---------------------------------------------------------------------------
Add-ReportLine '[2/6] DNS Resolution Tests' 'Yellow'
Add-ReportLine ('-' * 40)

$dnsResults = [System.Collections.ArrayList]::new()

foreach ($host_ in $TestHosts) {
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $resolved = Resolve-DnsName -Name $host_ -Type A -ErrorAction Stop | Select-Object -First 1
        $sw.Stop()

        $result = [PSCustomObject]@{
            Host      = $host_
            IP        = $resolved.IPAddress
            TimeMs    = $sw.ElapsedMilliseconds
            Status    = 'OK'
        }
        Add-ReportLine "  $host_ -> $($resolved.IPAddress) ($($sw.ElapsedMilliseconds) ms)" 'Green'
    }
    catch {
        $result = [PSCustomObject]@{
            Host      = $host_
            IP        = 'FAILED'
            TimeMs    = -1
            Status    = 'FAILED'
        }
        Add-ReportLine "  $host_ -> FAILED: $($_.Exception.Message)" 'Red'
    }
    [void]$dnsResults.Add($result)
}

# Test specific DNS servers
foreach ($dns in $dnsServers) {
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $resolved = Resolve-DnsName -Name 'www.microsoft.com' -Server $dns -Type A -ErrorAction Stop | Select-Object -First 1
        $sw.Stop()
        Add-ReportLine "  DNS Server $dns : OK ($($sw.ElapsedMilliseconds) ms)" 'Green'
    }
    catch {
        Add-ReportLine "  DNS Server $dns : FAILED" 'Red'
    }
}
Add-ReportBlank

# ---------------------------------------------------------------------------
# 3. Gateway Reachability
# ---------------------------------------------------------------------------
Add-ReportLine '[3/6] Gateway Reachability' 'Yellow'
Add-ReportLine ('-' * 40)

try {
    $gateways = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty NextHop -Unique

    if (-not $gateways) {
        $gateways = (Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration |
            Where-Object { $_.DefaultIPGateway }).DefaultIPGateway | Select-Object -Unique
    }

    foreach ($gw in $gateways) {
        if (-not $gw -or $gw -eq '0.0.0.0') { continue }

        $ping = Test-Connection -ComputerName $gw -Count 3 -Quiet -ErrorAction SilentlyContinue
        $latency = (Test-Connection -ComputerName $gw -Count 3 -ErrorAction SilentlyContinue |
            Measure-Object -Property ResponseTime -Average).Average

        if ($ping) {
            Add-ReportLine "  Gateway $gw : Reachable (avg $([math]::Round($latency, 1)) ms)" 'Green'
        }
        else {
            Add-ReportLine "  Gateway $gw : UNREACHABLE" 'Red'
        }
    }
}
catch {
    Add-ReportLine "  Could not test gateway: $($_.Exception.Message)" 'Red'
}
Add-ReportBlank

# ---------------------------------------------------------------------------
# 4. Internet Connectivity
# ---------------------------------------------------------------------------
Add-ReportLine '[4/6] Internet Connectivity' 'Yellow'
Add-ReportLine ('-' * 40)

foreach ($url in $testUrls) {
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        $sw.Stop()

        $statusCode = $response.StatusCode
        Add-ReportLine "  $url : HTTP $statusCode ($($sw.ElapsedMilliseconds) ms)" 'Green'
    }
    catch {
        Add-ReportLine "  $url : FAILED - $($_.Exception.Message)" 'Red'
    }
}

# Basic ping to internet - 8.8.8.8 is a public sentinel, not a private target.
# Suppression for this specific call is applied at the script param block at the top.
$internetPing = Test-Connection -ComputerName '8.8.8.8' -Count 2 -Quiet -ErrorAction SilentlyContinue
Add-ReportLine "  ICMP to 8.8.8.8: $(if ($internetPing) { 'OK' } else { 'FAILED' })" $(if ($internetPing) { 'Green' } else { 'Red' })
Add-ReportBlank

# ---------------------------------------------------------------------------
# 5. Port Connectivity
# ---------------------------------------------------------------------------
Add-ReportLine '[5/6] Port Connectivity Tests' 'Yellow'
Add-ReportLine ('-' * 40)

$portResults = [System.Collections.ArrayList]::new()

foreach ($target in $commonPorts) {
    $targetHost = $target.Host
    $targetPort = $target.Port
    $desc       = $target.Description

    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $asyncResult = $tcpClient.BeginConnect($targetHost, $targetPort, $null, $null)
        $wait = $asyncResult.AsyncWaitHandle.WaitOne(3000, $false)

        if ($wait -and $tcpClient.Connected) {
            $tcpClient.EndConnect($asyncResult)
            Add-ReportLine "  ${targetHost}:${targetPort} ($desc) : OPEN" 'Green'
            $status = 'Open'
        }
        else {
            Add-ReportLine "  ${targetHost}:${targetPort} ($desc) : CLOSED/TIMEOUT" 'Red'
            $status = 'Closed'
        }
        $tcpClient.Close()
    }
    catch {
        Add-ReportLine "  ${targetHost}:${targetPort} ($desc) : ERROR - $($_.Exception.Message)" 'Red'
        $status = 'Error'
    }

    [void]$portResults.Add([PSCustomObject]@{
        Host        = $targetHost
        Port        = $targetPort
        Description = $desc
        Status      = $status
    })
}
Add-ReportBlank

# ---------------------------------------------------------------------------
# 6. Traceroute
# ---------------------------------------------------------------------------
if (-not $SkipTraceroute) {
    Add-ReportLine "[6/6] Traceroute to $TracerouteTarget (max $MaxHops hops)" 'Yellow'
    Add-ReportLine ('-' * 40)

    try {
        $traceResults = Test-NetConnection -ComputerName $TracerouteTarget -TraceRoute -ErrorAction Stop

        if ($traceResults.TraceRoute) {
            $hop = 0
            foreach ($traceHop in $traceResults.TraceRoute) {
                $hop++
                try {
                    $hostEntry = [System.Net.Dns]::GetHostEntry($traceHop).HostName
                }
                catch {
                    $hostEntry = ''
                }
                $line = "  {0,3}  {1,-15}  {2}" -f $hop, $traceHop, $hostEntry
                Add-ReportLine $line 'White'

                if ($hop -ge $MaxHops) { break }
            }
        }

        Add-ReportLine "`n  Destination reachable: $($traceResults.TcpTestSucceeded)" $(if ($traceResults.TcpTestSucceeded) { 'Green' } else { 'Red' })
    }
    catch {
        Add-ReportLine "  Traceroute failed: $($_.Exception.Message)" 'Red'
    }
}
else {
    Add-ReportLine '[6/6] Traceroute - SKIPPED' 'DarkGray'
}

Add-ReportBlank
Add-ReportLine $divider 'Cyan'
Add-ReportLine '  Diagnostics Complete' 'Cyan'
Add-ReportLine $divider 'Cyan'
Add-ReportBlank

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------
if ($ExportPath) {
    $exportDir = Split-Path -Parent $ExportPath
    if ($exportDir -and -not (Test-Path $exportDir)) {
        New-Item -Path $exportDir -ItemType Directory -Force | Out-Null
    }
    $report.ToString() | Out-File -FilePath $ExportPath -Encoding UTF8
    Write-Host "Report exported to: $ExportPath" -ForegroundColor Green
}

if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
    $failedDns   = ($dnsResults | Where-Object Status -eq 'FAILED').Count
    $closedPorts = ($portResults | Where-Object Status -ne 'Open').Count
    Write-Log -Message "Network diagnostics completed. DNS failures: $failedDns, Port issues: $closedPorts"
}
