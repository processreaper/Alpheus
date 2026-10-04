# Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
# Every exclusion below was reviewed against this code base, not silenced wholesale.
@{
    Severity     = @('Error', 'Warning', 'Information')
    ExcludeRules = @(
        # Console tool: coloured, host-only progress text is the intended output; data goes to the
        # transcript and the JSON report, not the pipeline.
        'PSAvoidUsingWriteHost'
        # Internal UI helpers (Set-Busy, Update-Treemap, New-NodeItem, ...) change WPF state, not the
        # system. The engine applies ShouldProcess per cleanup category, where -WhatIf matters.
        'PSUseShouldProcessForStateChangingFunctions'
        # WPF event handlers must declare ($sender, $e) even when one is unused.
        'PSReviewUnusedParameter'
        # Names like Save-GridColumns / Get-CategoryBytes describe collections; script-private.
        'PSUseSingularNouns'
        # Empty catches are deliberate best-effort paths (partial size totals on enumeration errors,
        # layout restore falling back to defaults, declined UAC). Each was reviewed 2026-10-03; the one
        # that failed open (protected-path normalisation) now stops the run instead.
        'PSAvoidUsingEmptyCatchBlock'
        'PSAvoidUsingPositionalParameters'
    )
}
