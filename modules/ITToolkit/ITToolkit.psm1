<#
.SYNOPSIS
    Shared helper module for the IT Toolkit scripts.

.DESCRIPTION
    Provides common utility functions used across all IT Toolkit scripts,
    including structured logging, admin rights verification, configuration
    management, and notification delivery.

.NOTES
    Author:  Bastiaan Rusch
    Version: 1.0.0
#>

#Requires -Version 5.1

# ---------------------------------------------------------------------------
# Write-Log
# ---------------------------------------------------------------------------
function Write-Log {
    <#
    .SYNOPSIS
        Writes a structured log entry to file and optionally to the console.

    .DESCRIPTION
        Creates timestamped, leveled log entries in a consistent format.
        Log files are created per day in the configured log path.

    .PARAMETER Message
        The log message text.

    .PARAMETER Level
        Severity level: Information, Warning, or Error. Defaults to Information.

    .PARAMETER LogPath
        Directory for log files. Falls back to the path in settings.json,
        then to $env:TEMP\ITToolkit\Logs.

    .PARAMETER NoConsole
        Suppress console output; write to file only.

    .EXAMPLE
        Write-Log -Message "User created successfully" -Level Information

    .EXAMPLE
        Write-Log -Message "Disk space low" -Level Warning -LogPath "C:\Logs"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,

        [ValidateSet('Information', 'Warning', 'Error')]
        [string]$Level = 'Information',

        [string]$LogPath,

        [switch]$NoConsole
    )

    # Resolve log directory
    if (-not $LogPath) {
        try {
            $config = Get-Config -ErrorAction SilentlyContinue
            $LogPath = $config.Logging.Path
        }
        catch { }
    }
    if (-not $LogPath) {
        $LogPath = Join-Path $env:TEMP 'ITToolkit\Logs'
    }

    if (-not (Test-Path -Path $LogPath)) {
        New-Item -Path $LogPath -ItemType Directory -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $date      = Get-Date -Format 'yyyy-MM-dd'
    $logFile   = Join-Path $LogPath "ITToolkit_$date.log"
    $caller    = if ($MyInvocation.PSCommandPath) {
        Split-Path -Leaf $MyInvocation.PSCommandPath
    } else {
        'Interactive'
    }

    $entry = "[$timestamp] [$Level] [$caller] $Message"

    Add-Content -Path $logFile -Value $entry -Encoding UTF8

    if (-not $NoConsole) {
        switch ($Level) {
            'Warning'     { Write-Warning $Message }
            'Error'       { Write-Error   $Message }
            default       { Write-Verbose $Message }
        }
    }
}

# ---------------------------------------------------------------------------
# Test-AdminRights
# ---------------------------------------------------------------------------
function Test-AdminRights {
    <#
    .SYNOPSIS
        Tests whether the current session is running with administrator privileges.

    .DESCRIPTION
        Returns $true if the current PowerShell process is elevated, $false otherwise.
        Optionally throws a terminating error when elevation is required but missing.

    .PARAMETER Required
        If set, throws a terminating error when the session is not elevated.

    .EXAMPLE
        if (Test-AdminRights) { Write-Host "Running elevated" }

    .EXAMPLE
        Test-AdminRights -Required   # Throws if not admin
    #>
    [CmdletBinding()]
    param(
        [switch]$Required
    )

    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    $isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if ($Required -and -not $isAdmin) {
        throw 'This script requires administrator privileges. Please run as Administrator.'
    }

    return $isAdmin
}

# ---------------------------------------------------------------------------
# Get-Config
# ---------------------------------------------------------------------------
function Get-Config {
    <#
    .SYNOPSIS
        Reads the IT Toolkit settings.json configuration file.

    .DESCRIPTION
        Searches for settings.json in the config directory relative to the
        module location. Returns the parsed configuration object.

    .PARAMETER ConfigPath
        Override path to a specific settings file.

    .EXAMPLE
        $cfg = Get-Config
        $cfg.Organization.Domain

    .EXAMPLE
        $cfg = Get-Config -ConfigPath "C:\MyConfig\settings.json"
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigPath
    )

    if (-not $ConfigPath) {
        $moduleRoot = Split-Path -Parent $PSScriptRoot
        $ConfigPath = Join-Path $moduleRoot 'config\settings.json'
    }

    if (-not (Test-Path -Path $ConfigPath)) {
        $examplePath = $ConfigPath -replace '\.json$', '.example.json'
        if (Test-Path -Path $examplePath) {
            Write-Warning "settings.json not found. Copy '$examplePath' to '$ConfigPath' and update the values."
        }
        throw "Configuration file not found: $ConfigPath"
    }

    $raw = Get-Content -Path $ConfigPath -Raw -Encoding UTF8
    return $raw | ConvertFrom-Json
}

# ---------------------------------------------------------------------------
# Send-Notification
# ---------------------------------------------------------------------------
function Send-Notification {
    <#
    .SYNOPSIS
        Sends an email notification via SMTP.

    .DESCRIPTION
        Uses configuration from settings.json (or explicit parameters) to
        send an email message. Supports HTML body content.

    .PARAMETER To
        Recipient email address(es).

    .PARAMETER Subject
        Email subject line.

    .PARAMETER Body
        Email body content.

    .PARAMETER Html
        Treat the body as HTML content.

    .PARAMETER SmtpServer
        Override the SMTP server from config.

    .PARAMETER From
        Override the sender address from config.

    .PARAMETER Credential
        PSCredential for SMTP authentication.

    .EXAMPLE
        Send-Notification -To "admin@contoso.com" -Subject "Alert" -Body "Disk space low"

    .EXAMPLE
        Send-Notification -To "user@contoso.com" -Subject "Welcome" -Body $htmlBody -Html
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string[]]$To,

        [Parameter(Mandatory)]
        [string]$Subject,

        [Parameter(Mandatory)]
        [string]$Body,

        [switch]$Html,

        [string]$SmtpServer,

        [string]$From,

        [PSCredential]$Credential
    )

    # Load defaults from config
    if (-not $SmtpServer -or -not $From) {
        try {
            $config = Get-Config -ErrorAction SilentlyContinue
            if (-not $SmtpServer) { $SmtpServer = $config.Organization.SmtpServer }
            if (-not $From)       { $From       = $config.Organization.SmtpFrom }
        }
        catch {
            if (-not $SmtpServer) { throw 'SMTP server not specified and config unavailable.' }
            if (-not $From)       { throw 'Sender address not specified and config unavailable.' }
        }
    }

    $mailParams = @{
        To         = $To
        From       = $From
        Subject    = $Subject
        Body       = $Body
        SmtpServer = $SmtpServer
        Port       = 587
        UseSsl     = $true
    }

    if ($Html)       { $mailParams['BodyAsHtml'] = $true }
    if ($Credential) { $mailParams['Credential'] = $Credential }

    if ($PSCmdlet.ShouldProcess("$($To -join ', ')", "Send email: $Subject")) {
        Send-MailMessage @mailParams
        Write-Log -Message "Notification sent to $($To -join ', '): $Subject"
    }
}

# ---------------------------------------------------------------------------
# Module exports
# ---------------------------------------------------------------------------
Export-ModuleMember -Function Write-Log, Test-AdminRights, Get-Config, Send-Notification
