# powershell-it-toolkit

A collection of PowerShell scripts and modules for Windows endpoint and IT
administration tasks. Maintained by Bastiaan ([@bastiaan365](https://github.com/bastiaan365)).

This file scopes Claude's behaviour for this repo. The global `~/.claude/CLAUDE.md`
covers personal conventions; everything below is repo-specific.

## Audience and assumptions

- Target shell: **PowerShell 7+** (cross-platform). Flag Windows PowerShell 5.1-only constructs unless the script is explicitly tagged `# Requires -Version 5.1`.
- Users are IT admins running scripts ad-hoc or via scheduled tasks. Assume non-interactive execution must be possible.
- Scripts may run on locked-down endpoints. Minimise external module dependencies; prefer built-in cmdlets. When a module is required, list it under `# Requires -Module` and gracefully exit if it's missing.

## Repo conventions

### Structure

```
/Modules/<ModuleName>/   <- proper PowerShell modules with .psd1 + .psm1
/Scripts/<Category>/     <- standalone .ps1 scripts grouped by purpose
/Tests/                  <- Pester v5 tests, mirroring source structure
/docs/                   <- markdown docs, one per module/script
/examples/               <- runnable example invocations
```

If the repo doesn't yet match this layout, treat the gap as a backlog item — note it in `## Drift from target structure` at the bottom of this file rather than aggressively reorganising.

### Naming

- **Verb-Noun** with approved verbs only (`Get-Verb` to check). PascalCase nouns, singular.
- Private/helper functions prefixed with underscore: `_Format-Output`.
- Parameters: PascalCase, full names, no abbreviations (`-ComputerName`, not `-CN`).
- Files match the primary function name: `Get-DiskHealth.ps1` exports `Get-DiskHealth`.

### Style

- Always include comment-based help: `.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, `.EXAMPLE` (at least one), `.NOTES`.
- `[CmdletBinding()]` on every advanced function. `SupportsShouldProcess` on anything destructive.
- `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'` at the top of scripts and module root files.
- `try`/`catch` with structured error records over silent failure.
- Output **objects**, not formatted strings. Let the caller decide formatting.
- No `Write-Host` for data — use `Write-Output` or just leave the object on the pipeline. Reserve `Write-Host` for genuine UI (progress, prompts).
- No backticks for line continuation. Use splatting or natural line breaks (after `|`, `,`, etc).

### Testing

- Pester v5 tests required for any new function in a module.
- Cover at minimum: happy path, parameter validation, error handling, one mock for any external call.
- Run locally: `Invoke-Pester ./Tests -Output Detailed`
- A passing test suite is a precondition for any PR. Don't propose merging if tests fail.

### Security

- Never hardcode credentials, tokens, hostnames, or IP addresses from my environments. Use parameters or config files.
- Use `[SecureString]` or `PSCredential` for secrets.
- Flag scripts touching AD, registry, or remote endpoints in the `.NOTES` block with required permissions and minimum privilege needed.
- Anything that writes to AD, modifies firewall rules, or touches system services is destructive — `SupportsShouldProcess` is non-negotiable.

## Workflow expectations for Claude

When I ask you to **add or modify a script**:

1. Read 2-3 existing similar scripts first to match established style. Don't reinvent.
2. Show the change as a diff or full file preview before writing.
3. Run `Invoke-ScriptAnalyzer` mentally (or actually, if PSSA is installed) and call out any warnings.
4. Update or add Pester tests in the same change.
5. Update the relevant doc in `/docs/` if the public surface changes.

When I ask for a **new feature**:

1. Ask clarifying questions only if a decision would meaningfully change the design. Otherwise pick a reasonable default and state it.
2. Suggest where it belongs in the structure (module vs script, which category).
3. If the feature spans multiple files, propose the split before writing any of them.

When **fixing a bug**:

1. Reproduce mentally first; explain root cause before patching.
2. Add a regression test in the same commit.
3. Note the root cause in the commit message, not just the symptom.

When **reviewing my code**:

1. Be direct. If something is wrong, say so. If it's just a style preference, say that too — don't conflate the two.
2. Suggest the fix, don't just point at the problem.
3. Flag security concerns first, correctness second, style last.

## Things to avoid

- `Invoke-Expression` on anything resembling user input
- Aliases in committed code (`%`, `?`, `gci`, `ls`, `gc`, `cd`) — full cmdlet names only
- Positional parameters in scripts intended for reuse
- `-ErrorAction SilentlyContinue` without a comment explaining why
- Catching exceptions just to swallow them; either handle or rethrow with context
- Modifying `$PSDefaultParameterValues` in scripts (caller's environment is theirs)

## Useful context

- Maintainer GitHub: `bastiaan365`
- Personal site: `bastiaan365.com`
- Related repos in the same ecosystem: `grafana-dashboards`, `bastiaan365` (profile)
- This repo is part of a public portfolio. README quality, examples, and docs matter as much as the code.

## Drift from target structure

_Claude maintains this section. List anything in the repo that doesn't match the conventions above, with why it's still there and what would need to happen to fix it._

- **Lowercase directory names** (`modules/`, `scripts/`, `config/`) instead of PascalCase. Cosmetic; PowerShell on Windows is case-insensitive but Linux filesystems aren't. To fix: `git mv` to PascalCase when there's a natural reason to touch them.
- **`modules/ITToolkit.psm1` is a flat file**, not `modules/ITToolkit/ITToolkit.psd1 + .psm1`. To fix: scaffold the subdirectory + manifest with `New-ModuleManifest`, move the `.psm1` into it, declare exported functions. Worth doing before the module gains a second function.
- **`scripts/` has no category subdirectories** — eight `.ps1` files at the top level. To fix: group by purpose (e.g. `endpoint/`, `identity/`, `network/`, `m365/`) once each bucket has enough scripts to justify it.
- **No `Tests/` directory** — no Pester coverage exists. Heredoc requires Pester for new module functions; existing scripts are uncovered. To fix: backfill tests for `ITToolkit.psm1` first, then add tests alongside any new function.
- **No `docs/` or `examples/` directories.** Comment-based help in script headers is currently the only documentation. To fix: add once the public surface outgrows README + inline help.
- **`config/` is not in target structure but is in the repo** (holds `settings.example.json`). Reasonable place for it; treat as accepted convention rather than drift.
