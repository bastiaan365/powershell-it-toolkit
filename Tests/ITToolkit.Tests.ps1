<#
.SYNOPSIS
    Pester v5 tests for the ITToolkit module.

.DESCRIPTION
    Covers Write-Log, Test-AdminRights, Get-Config, Send-Notification.
    Uses InModuleScope + Mock for Send-MailMessage and Get-Config.
    Test-AdminRights is Windows-only and skipped on non-Windows hosts.

.NOTES
    Run from the repo root:  Invoke-Pester ./Tests -Output Detailed
#>

BeforeAll {
    $script:repoRoot   = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
    $script:modulePath = Join-Path $script:repoRoot 'modules/ITToolkit'
    Import-Module $script:modulePath -Force
}

AfterAll {
    Remove-Module ITToolkit -ErrorAction SilentlyContinue
}

Describe 'Write-Log' {

    It 'Creates the log directory if it does not exist' {
        $logDir = Join-Path $TestDrive 'newdir'
        Write-Log -Message 'create-dir-test' -LogPath $logDir -NoConsole
        Test-Path -Path $logDir -PathType Container | Should -BeTrue
    }

    It 'Writes a timestamped, leveled entry to a daily log file' {
        $logDir = Join-Path $TestDrive 'entries'
        Write-Log -Message 'happy-path' -Level Warning -LogPath $logDir -NoConsole
        $today  = Get-Date -Format 'yyyy-MM-dd'
        $logFile = Join-Path $logDir "ITToolkit_$today.log"
        Test-Path $logFile | Should -BeTrue
        $content = Get-Content $logFile -Raw
        $content | Should -Match '\[Warning\]'
        $content | Should -Match 'happy-path'
        $content | Should -Match '\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]'
    }

    It 'Defaults to Information level when -Level is omitted' {
        $logDir = Join-Path $TestDrive 'defaultlevel'
        Write-Log -Message 'default-level-test' -LogPath $logDir -NoConsole
        $today  = Get-Date -Format 'yyyy-MM-dd'
        $logFile = Join-Path $logDir "ITToolkit_$today.log"
        (Get-Content $logFile -Raw) | Should -Match '\[Information\]'
    }

    It 'Rejects an invalid log level via parameter validation' {
        { Write-Log -Message 'bad' -Level 'NotALevel' -NoConsole } |
            Should -Throw -ErrorId 'ParameterArgumentValidationError*'
    }

    It 'Accepts pipeline input via positional Message parameter' {
        $logDir = Join-Path $TestDrive 'positional'
        Write-Log 'positional-test' -LogPath $logDir -NoConsole
        $today  = Get-Date -Format 'yyyy-MM-dd'
        (Get-Content (Join-Path $logDir "ITToolkit_$today.log") -Raw) |
            Should -Match 'positional-test'
    }

    It 'Falls back to a cross-platform temp dir when LogPath unset and config unavailable' {
        # Regression: previously hardcoded $env:TEMP + '\' which broke on Linux.
        InModuleScope ITToolkit {
            Mock Get-Config { throw 'no config' }
            { Write-Log -Message 'fallback-test' -NoConsole } | Should -Not -Throw
            $today    = Get-Date -Format 'yyyy-MM-dd'
            $expected = Join-Path ([System.IO.Path]::GetTempPath()) (Join-Path 'ITToolkit' 'Logs')
            $logFile  = Join-Path $expected "ITToolkit_$today.log"
            Test-Path $logFile | Should -BeTrue
        }
    }
}

Describe 'Test-AdminRights' -Skip:(-not $IsWindows) {

    It 'Returns a boolean' {
        $result = Test-AdminRights
        $result | Should -BeOfType [bool]
    }

    It 'Throws when -Required is set and the session is not elevated' {
        InModuleScope ITToolkit {
            # Force the function to take the not-admin branch by overriding the principal check.
            # The function calls .IsInRole(Administrator); we cannot easily mock a static .NET call,
            # so we only assert the throw shape when the underlying check returns $false.
            $current = [Security.Principal.WindowsIdentity]::GetCurrent()
            $isAdmin = ([Security.Principal.WindowsPrincipal]$current).IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator
            )
            if (-not $isAdmin) {
                { Test-AdminRights -Required } | Should -Throw -ExpectedMessage '*administrator privileges*'
            }
        }
    }
}

Describe 'Get-Config' {

    It 'Throws when the configuration file does not exist' {
        $missing = Join-Path $TestDrive 'no-such-config.json'
        { Get-Config -ConfigPath $missing } |
            Should -Throw -ExpectedMessage '*Configuration file not found*'
    }

    It 'Returns a parsed object for a valid JSON file' {
        $configFile = Join-Path $TestDrive 'good.json'
        @'
{
    "Organization": { "Name": "TestCorp", "Domain": "test.local" }
}
'@ | Set-Content -Path $configFile -Encoding UTF8

        $cfg = Get-Config -ConfigPath $configFile
        $cfg.Organization.Name   | Should -Be 'TestCorp'
        $cfg.Organization.Domain | Should -Be 'test.local'
    }

    It 'Throws on invalid JSON' {
        $configFile = Join-Path $TestDrive 'bad.json'
        '{ this is not valid json' | Set-Content -Path $configFile -Encoding UTF8
        { Get-Config -ConfigPath $configFile } | Should -Throw
    }

    It 'Warns when a sibling .example.json exists but the real config does not' {
        $exampleFile = Join-Path $TestDrive 'settings.example.json'
        $missingFile = Join-Path $TestDrive 'settings.json'
        '{ "Organization": { "Name": "Sample" } }' |
            Set-Content -Path $exampleFile -Encoding UTF8

        $warnings = $null
        try {
            Get-Config -ConfigPath $missingFile -WarningVariable warnings -ErrorAction SilentlyContinue 3>$null
        } catch { }

        $warnings.Count | Should -BeGreaterThan 0
        $warnings[0].Message | Should -Match 'settings.json not found'
    }
}

Describe 'Send-Notification' {

    It 'Does not invoke Send-MailMessage when -WhatIf is supplied' {
        InModuleScope ITToolkit {
            Mock Send-MailMessage { } -Verifiable
            Send-Notification -To 'a@b.c' -Subject 's' -Body 'b' `
                -SmtpServer 'smtp.test' -From 'from@test' -WhatIf
            Should -Invoke Send-MailMessage -Times 0 -Exactly
        }
    }

    It 'Invokes Send-MailMessage with BodyAsHtml when -Html is supplied' {
        InModuleScope ITToolkit {
            Mock Send-MailMessage { } -ParameterFilter { $BodyAsHtml -eq $true }
            Mock Write-Log { }   # decouple: the test asserts about email, not logging
            Send-Notification -To 'a@b.c' -Subject 's' -Body '<p>x</p>' -Html `
                -SmtpServer 'smtp.test' -From 'from@test' -Confirm:$false
            Should -Invoke Send-MailMessage -Times 1 -Exactly `
                -ParameterFilter { $BodyAsHtml -eq $true }
        }
    }

    It 'Passes To, From, Subject, Body, and SmtpServer through to Send-MailMessage' {
        InModuleScope ITToolkit {
            Mock Send-MailMessage { }
            Mock Write-Log { }
            Send-Notification -To 'recipient@example.com' -Subject 'subj' -Body 'body' `
                -SmtpServer 'mail.example' -From 'sender@example.com' -Confirm:$false
            Should -Invoke Send-MailMessage -Times 1 -Exactly -ParameterFilter {
                $To -contains 'recipient@example.com' -and
                $From       -eq 'sender@example.com'  -and
                $Subject    -eq 'subj'                -and
                $Body       -eq 'body'                -and
                $SmtpServer -eq 'mail.example'
            }
        }
    }

    It 'Throws when SmtpServer is missing and config cannot supply it' {
        InModuleScope ITToolkit {
            Mock Get-Config { throw 'no config' }
            { Send-Notification -To 'a@b.c' -Subject 's' -Body 'b' -From 'from@test' -Confirm:$false } |
                Should -Throw -ExpectedMessage '*SMTP server*'
        }
    }

    It 'Throws when From is missing and config cannot supply it' {
        InModuleScope ITToolkit {
            Mock Get-Config { throw 'no config' }
            { Send-Notification -To 'a@b.c' -Subject 's' -Body 'b' -SmtpServer 'smtp.test' -Confirm:$false } |
                Should -Throw -ExpectedMessage '*Sender address*'
        }
    }
}
