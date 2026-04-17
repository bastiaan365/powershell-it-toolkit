@{
    RootModule        = 'ITToolkit.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b0867570-f131-4a09-ab2c-ce21ff2129b5'

    Author            = 'Bastiaan Rusch'
    CompanyName       = 'bastiaan365'
    Copyright         = '(c) Bastiaan Rusch. Released under the MIT License.'

    Description       = 'Shared helper module for the powershell-it-toolkit scripts. Provides structured logging, admin-rights verification, JSON configuration loading, and SMTP notifications.'

    PowerShellVersion = '5.1'

    FunctionsToExport = @('Write-Log', 'Test-AdminRights', 'Get-Config', 'Send-Notification')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('IT', 'PowerShell', 'Helpers', 'Toolkit', 'Logging', 'AD', 'M365')
            LicenseUri   = 'https://github.com/bastiaan365/powershell-it-toolkit/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/bastiaan365/powershell-it-toolkit'
            ReleaseNotes = 'Initial module manifest. Functions extracted from a flat .psm1 into a proper module structure.'
        }
    }
}
