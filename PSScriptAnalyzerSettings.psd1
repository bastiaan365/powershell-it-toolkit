@{
    # Settings consumed by:
    #   Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
    # and by the GitHub Actions CI workflow.

    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # The 8 user-facing scripts intentionally use Write-Host for progress output
        # and coloured headers. Data is returned via Write-Output / pipeline objects.
        'PSAvoidUsingWriteHost'
    )

    # All other rules at default severity. Per-target exceptions are applied via
    # [Diagnostics.CodeAnalysis.SuppressMessageAttribute] in the source, with a
    # Justification string explaining why.
}
