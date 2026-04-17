<#
.SYNOPSIS
    Automates new user provisioning in Active Directory and Microsoft 365.

.DESCRIPTION
    Creates a new user account with the following steps:
    1. Create AD user account with standard attributes
    2. Add user to default security and distribution groups
    3. Assign Microsoft 365 license via Microsoft Graph
    4. Create home folder with appropriate permissions
    5. Send welcome email to the user's manager

    Reads organization defaults from config/settings.json.

.PARAMETER FirstName
    User's first name (given name).

.PARAMETER LastName
    User's last name (surname).

.PARAMETER Department
    User's department (e.g., "IT", "Finance", "HR").

.PARAMETER JobTitle
    User's job title.

.PARAMETER Manager
    SamAccountName of the user's manager.

.PARAMETER Password
    Initial password as a SecureString. If not provided, a random password is generated.

.PARAMETER OU
    Distinguished Name of the target OU. Overrides the default from config.

.EXAMPLE
    .\New-UserOnboarding.ps1 -FirstName "Jane" -LastName "Smith" -Department "IT" -JobTitle "Systems Engineer"

.EXAMPLE
    .\New-UserOnboarding.ps1 -FirstName "John" -LastName "Doe" -Department "Finance" -JobTitle "Analyst" -Manager "jsmith" -WhatIf

.NOTES
    Author:  Bastiaan Rusch
    Version: 1.0.0
    Requires: ActiveDirectory module, Microsoft.Graph module
#>

#Requires -Version 5.1
#Requires -Modules ActiveDirectory

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$FirstName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$LastName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Department,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$JobTitle,

    [string]$Manager,

    [SecureString]$Password,

    [string]$OU
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Import shared module
$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'modules/ITToolkit'
if (Test-Path $modulePath) {
    Import-Module $modulePath -Force
}

# ---------------------------------------------------------------------------
# Load configuration
# ---------------------------------------------------------------------------
try {
    $config = Get-Config
}
catch {
    Write-Warning "Could not load settings.json. Using built-in defaults."
    $config = [PSCustomObject]@{
        Organization = [PSCustomObject]@{
            Domain         = 'contoso.com'
            DefaultOU      = 'OU=Users,OU=Corporate,DC=contoso,DC=com'
            HomeFolderRoot = '\\fileserver\home$'
            SmtpServer     = 'smtp.contoso.com'
            SmtpFrom       = 'it-automation@contoso.com'
        }
        M365 = [PSCustomObject]@{
            LicenseSkuId  = '00000000-0000-0000-0000-000000000000'
            UsageLocation = 'US'
            DefaultGroups = @('All-Staff', 'M365-BasicUsers')
        }
    }
}

$domain         = $config.Organization.Domain
$defaultOU      = if ($OU) { $OU } else { $config.Organization.DefaultOU }
$homeFolderRoot = $config.Organization.HomeFolderRoot

# ---------------------------------------------------------------------------
# Derive user attributes
# ---------------------------------------------------------------------------
$samAccountName = ("$($FirstName[0])$LastName").ToLower() -replace '[^a-z0-9]', ''
$upn            = "$samAccountName@$domain"
$displayName    = "$FirstName $LastName"
$homeFolder     = Join-Path $homeFolderRoot $samAccountName

# Generate random password if not provided
if (-not $Password) {
    Add-Type -AssemblyName System.Web
    $plainPassword = [System.Web.Security.Membership]::GeneratePassword(16, 3)
    $Password = ConvertTo-SecureString -String $plainPassword -AsPlainText -Force
    Write-Verbose "Generated random password for $samAccountName"
}

Write-Host "`n=== New User Onboarding ===" -ForegroundColor Cyan
Write-Host "Name:       $displayName"
Write-Host "Username:   $samAccountName"
Write-Host "UPN:        $upn"
Write-Host "Department: $Department"
Write-Host "Title:      $JobTitle"
Write-Host "OU:         $defaultOU"
Write-Host ""

# ---------------------------------------------------------------------------
# Step 1: Create AD User
# ---------------------------------------------------------------------------
Write-Host "[1/5] Creating Active Directory account..." -ForegroundColor Yellow

$adParams = @{
    Name              = $displayName
    GivenName         = $FirstName
    Surname           = $LastName
    SamAccountName    = $samAccountName
    UserPrincipalName = $upn
    DisplayName       = $displayName
    Department        = $Department
    Title             = $JobTitle
    Path              = $defaultOU
    AccountPassword   = $Password
    Enabled           = $true
    ChangePasswordAtLogon = $true
    HomeDirectory     = $homeFolder
    HomeDrive         = 'H:'
}

if ($Manager) {
    $adParams['Manager'] = $Manager
}

if ($PSCmdlet.ShouldProcess($displayName, 'Create AD user account')) {
    try {
        New-ADUser @adParams
        Write-Host "  AD account created: $samAccountName" -ForegroundColor Green
        Write-Log -Message "AD account created: $samAccountName ($displayName)"
    }
    catch {
        Write-Log -Message "Failed to create AD account: $samAccountName - $_" -Level Error
        throw
    }
}

# ---------------------------------------------------------------------------
# Step 2: Add to default groups
# ---------------------------------------------------------------------------
Write-Host "[2/5] Adding to default groups..." -ForegroundColor Yellow

$defaultGroups = @($config.M365.DefaultGroups)
# Add department-specific group
$deptGroup = "$Department-Users"
$defaultGroups += $deptGroup

foreach ($group in $defaultGroups) {
    if ($PSCmdlet.ShouldProcess("$samAccountName -> $group", 'Add to group')) {
        try {
            Add-ADGroupMember -Identity $group -Members $samAccountName -ErrorAction Stop
            Write-Host "  Added to group: $group" -ForegroundColor Green
        }
        catch {
            Write-Warning "  Could not add to group '$group': $($_.Exception.Message)"
        }
    }
}

# ---------------------------------------------------------------------------
# Step 3: Assign M365 License via Microsoft Graph
# ---------------------------------------------------------------------------
Write-Host "[3/5] Assigning Microsoft 365 license..." -ForegroundColor Yellow

if ($PSCmdlet.ShouldProcess($upn, 'Assign M365 license')) {
    try {
        # Ensure Microsoft Graph connection
        $context = Get-MgContext -ErrorAction SilentlyContinue
        if (-not $context) {
            Write-Verbose "Connecting to Microsoft Graph..."
            Connect-MgGraph -Scopes 'User.ReadWrite.All', 'Directory.ReadWrite.All' -NoWelcome
        }

        # Wait briefly for AD sync to propagate the user to Entra ID
        Write-Verbose "Waiting for directory sync..."
        Start-Sleep -Seconds 10

        # Set usage location (required before license assignment)
        $mgUser = Get-MgUser -Filter "userPrincipalName eq '$upn'" -ErrorAction Stop
        Update-MgUser -UserId $mgUser.Id -UsageLocation $config.M365.UsageLocation

        # Assign license
        $licenseParams = @{
            AddLicenses    = @(@{ SkuId = $config.M365.LicenseSkuId })
            RemoveLicenses = @()
        }
        Set-MgUserLicense -UserId $mgUser.Id -BodyParameter $licenseParams
        Write-Host "  M365 license assigned" -ForegroundColor Green
        Write-Log -Message "M365 license assigned to $upn"
    }
    catch {
        Write-Warning "  Could not assign M365 license: $($_.Exception.Message)"
        Write-Log -Message "M365 license assignment failed for $upn - $_" -Level Warning
    }
}

# ---------------------------------------------------------------------------
# Step 4: Create Home Folder
# ---------------------------------------------------------------------------
Write-Host "[4/5] Creating home folder..." -ForegroundColor Yellow

if ($PSCmdlet.ShouldProcess($homeFolder, 'Create home folder')) {
    try {
        if (-not (Test-Path -Path $homeFolder)) {
            New-Item -Path $homeFolder -ItemType Directory -Force | Out-Null
        }

        # Set NTFS permissions
        $acl = Get-Acl -Path $homeFolder
        $accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "$domain\$samAccountName",
            'Modify',
            'ContainerInherit,ObjectInherit',
            'None',
            'Allow'
        )
        $acl.AddAccessRule($accessRule)
        Set-Acl -Path $homeFolder -AclObject $acl

        Write-Host "  Home folder created: $homeFolder" -ForegroundColor Green
        Write-Log -Message "Home folder created: $homeFolder"
    }
    catch {
        Write-Warning "  Could not create home folder: $($_.Exception.Message)"
        Write-Log -Message "Home folder creation failed for $samAccountName - $_" -Level Warning
    }
}

# ---------------------------------------------------------------------------
# Step 5: Send Welcome Email
# ---------------------------------------------------------------------------
Write-Host "[5/5] Sending welcome email..." -ForegroundColor Yellow

if ($Manager -and $PSCmdlet.ShouldProcess($Manager, 'Send welcome email to manager')) {
    try {
        $managerObj = Get-ADUser -Identity $Manager -Properties EmailAddress -ErrorAction Stop
        $managerEmail = $managerObj.EmailAddress

        if ($managerEmail) {
            $welcomeBody = @"
<html>
<body style="font-family: Segoe UI, Arial, sans-serif;">
<h2>New Employee Account Created</h2>
<p>A new account has been provisioned for <strong>$displayName</strong>.</p>
<table border="0" cellpadding="5">
<tr><td><strong>Username:</strong></td><td>$samAccountName</td></tr>
<tr><td><strong>Email:</strong></td><td>$upn</td></tr>
<tr><td><strong>Department:</strong></td><td>$Department</td></tr>
<tr><td><strong>Job Title:</strong></td><td>$JobTitle</td></tr>
<tr><td><strong>Home Folder:</strong></td><td>$homeFolder</td></tr>
</table>
<p>The user must change their password at first logon.</p>
<p>Please contact the IT Help Desk if you have any questions.</p>
</body>
</html>
"@

            Send-Notification -To $managerEmail `
                -Subject "New Account Created: $displayName" `
                -Body $welcomeBody -Html

            Write-Host "  Welcome email sent to $managerEmail" -ForegroundColor Green
        }
        else {
            Write-Warning "  Manager '$Manager' has no email address on file."
        }
    }
    catch {
        Write-Warning "  Could not send welcome email: $($_.Exception.Message)"
    }
}
elseif (-not $Manager) {
    Write-Host "  No manager specified - skipping welcome email" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host "`n=== Onboarding Complete ===" -ForegroundColor Green
Write-Host "User '$displayName' ($samAccountName) has been provisioned."
if ($WhatIfPreference) {
    Write-Host "(WhatIf mode - no changes were made)" -ForegroundColor DarkYellow
}
Write-Host ""
