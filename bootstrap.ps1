<#
.SYNOPSIS
  Bootstrap the Claude Code cross-project memory system on this machine.

.DESCRIPTION
  Idempotent setup that:

    1. Creates ~/.claude/memory/ if absent.
    2. Seeds ~/.claude/memory/MEMORY.md from MEMORY.md.template if absent.
       If present, compares the *preamble* (everything above the
       '## Entries' heading) against the template and reports drift. The
       Entries section is per-machine and is never touched.
    3. Creates ~/.claude/CLAUDE.md with a minimal header if absent.
    4. Appends the cross-project memory section to ~/.claude/CLAUDE.md if
       absent. If present, compares the section body against the snippet
       and reports drift.
    5. Seeds ~/.claude/hooks/REGISTRY.md (an empty hooks ledger) from
       REGISTRY.md.template if absent; otherwise drift-checks its preamble
       (above '## Registered hooks'). This is plain Markdown -- it is NOT a
       hook and never mutates settings.json. The scaffold installs no hooks.

  Drift detection means the file's managed region differs from the
  canonical content shipped in this repo. By default, drift is reported
  with a diff but not corrected. Re-run with -Force to rewrite drifted
  regions with the canonical content. Hand-customisations inside those
  regions will be lost; customisations outside them are preserved.

  -WhatIf shows what would change without writing anything.

  Run from a clone of the claude-global-memory repo:

    .\bootstrap.ps1                   # report drift, do not fix
    .\bootstrap.ps1 -Force            # report and fix
    .\bootstrap.ps1 -Force -WhatIf    # show what -Force would do

  If PowerShell's execution policy blocks the script, run once via:

    powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1

  Or set the user-scope policy once:

    Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

  Script is ASCII-only so it parses cleanly under Windows PowerShell 5.1
  (which reads .ps1 source files as CP-1252).
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [switch]$Force,
    [switch]$InstallCloseout,
    [switch]$UninstallCloseout
)

$ErrorActionPreference = 'Stop'

$repoRoot    = $PSScriptRoot
$claudeHome  = Join-Path $env:USERPROFILE '.claude'
$memoryDir   = Join-Path $claudeHome 'memory'
$memoryIndex = Join-Path $memoryDir 'MEMORY.md'
$claudeMd    = Join-Path $claudeHome 'CLAUDE.md'
$template    = Join-Path $repoRoot 'MEMORY.md.template'
$snippet     = Join-Path $repoRoot 'snippets\cross-project-memory-claude-md.md'
$hooksDir         = Join-Path $claudeHome 'hooks'
$registry         = Join-Path $hooksDir 'REGISTRY.md'
$registryTemplate = Join-Path $repoRoot 'REGISTRY.md.template'
$skillsDir        = Join-Path $claudeHome 'skills'
$closeoutDir      = Join-Path $skillsDir 'closeout'
$closeoutTarget   = Join-Path $closeoutDir 'SKILL.md'
$closeoutStamp    = Join-Path $closeoutDir '.delivered'
$closeoutSource   = Join-Path $repoRoot 'skills\closeout\SKILL.md'

if (-not (Test-Path $template)) {
    throw "Template not found at $template -- run this script from a clone of the claude-global-memory repo."
}
if (-not (Test-Path $snippet)) {
    throw "Snippet not found at $snippet -- run this script from a clone of the claude-global-memory repo."
}
if (-not (Test-Path $registryTemplate)) {
    throw "Registry template not found at $registryTemplate -- run this script from a clone of the claude-global-memory repo."
}

# ---- helpers -------------------------------------------------------------

function Read-NormalizedLines($path) {
    # Returns the file as an array of lines with CRLF normalized to LF and
    # trailing whitespace stripped per line. No trailing blank lines.
    $raw = Get-Content -Path $path -Raw -Encoding utf8
    if ($null -eq $raw) { return @() }
    $raw = $raw -replace "`r`n", "`n"
    $lines = $raw -split "`n"
    $lines = $lines | ForEach-Object { $_ -replace '[\s]+$', '' }
    # Drop trailing empty lines
    while ($lines.Count -gt 0 -and $lines[-1] -eq '') {
        $lines = $lines[0..($lines.Count - 2)]
    }
    return ,@($lines)
}

function Find-LineIndex($lines, $pattern) {
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $pattern) { return $i }
    }
    return -1
}

function Get-ClaudeMdSection($lines) {
    # Returns @{StartIdx; EndIdx (exclusive); Section (string)} or $null.
    $startIdx = Find-LineIndex $lines '^## Cross-project memory\s*$'
    if ($startIdx -lt 0) { return $null }
    $endIdx = $lines.Count
    for ($j = $startIdx + 1; $j -lt $lines.Count; $j++) {
        if ($lines[$j] -match '^## ') { $endIdx = $j; break }
    }
    # Trim trailing blank lines inside the section so equality is stable.
    $sectionEnd = $endIdx
    while ($sectionEnd -gt ($startIdx + 1) -and $lines[$sectionEnd - 1] -eq '') {
        $sectionEnd--
    }
    $sectionLines = $lines[$startIdx..($sectionEnd - 1)]
    return @{
        StartIdx     = $startIdx
        EndIdx       = $endIdx
        SectionLines = $sectionLines
        Section      = ($sectionLines -join "`n")
    }
}

function Get-PreambleRegion($lines, $markerPattern) {
    # Returns @{MarkerIdx; Preamble (string); PreambleLines} or $null.
    # The preamble is everything above the first line matching $markerPattern;
    # the marker line and everything below is the per-machine tail.
    $markerIdx = Find-LineIndex $lines $markerPattern
    if ($markerIdx -lt 0) { return $null }
    if ($markerIdx -eq 0) {
        $preambleLines = @()
    } else {
        $preambleLines = $lines[0..($markerIdx - 1)]
    }
    # Trim trailing blank lines from the preamble for stable equality.
    while ($preambleLines.Count -gt 0 -and $preambleLines[-1] -eq '') {
        $preambleLines = $preambleLines[0..($preambleLines.Count - 2)]
    }
    return @{
        MarkerIdx     = $markerIdx
        PreambleLines = $preambleLines
        Preamble      = ($preambleLines -join "`n")
    }
}

function Show-Diff($label, $liveText, $canonicalText) {
    Write-Host ""
    Write-Host "  ---- diff: $label ----"
    $liveLines  = $liveText  -split "`n"
    $canonLines = $canonicalText -split "`n"
    # Longest common prefix
    $p = 0
    while ($p -lt $liveLines.Count -and $p -lt $canonLines.Count -and $liveLines[$p] -eq $canonLines[$p]) { $p++ }
    # Longest common suffix
    $s = 0
    while ($s -lt ($liveLines.Count - $p) -and $s -lt ($canonLines.Count - $p) -and `
           $liveLines[$liveLines.Count - 1 - $s] -eq $canonLines[$canonLines.Count - 1 - $s]) { $s++ }
    if ($p -gt 0) { Write-Host ("    ... $p line(s) unchanged before ...") }
    for ($k = $p; $k -lt ($liveLines.Count - $s); $k++) {
        Write-Host ("  - " + $liveLines[$k])
    }
    for ($k = $p; $k -lt ($canonLines.Count - $s); $k++) {
        Write-Host ("  + " + $canonLines[$k])
    }
    if ($s -gt 0) { Write-Host ("    ... $s line(s) unchanged after ...") }
    Write-Host "  ---- end diff ----"
    Write-Host ""
}

function Write-File($path, $lines) {
    # Join with platform newline so Windows keeps CRLF and Unix keeps LF.
    $nl = [System.Environment]::NewLine
    $content = ($lines -join $nl) + $nl
    Set-Content -Path $path -Value $content -Encoding utf8 -NoNewline
}

function Get-NormalizedHash($path) {
    # SHA-256 of the file's normalized content (CRLF->LF, trailing ws/blank
    # lines stripped), so the stamp survives CRLF/LF differences on Windows.
    $text = (Read-NormalizedLines $path) -join "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Test-IsReparsePoint($path) {
    # True if $path is a symlink/junction (a reparse point) -- we must never
    # write through one or we'd clobber its target.
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $item = Get-Item -LiteralPath $path -Force
    return [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

function Install-Closeout($closeoutSource, $closeoutDir, $closeoutTarget, $closeoutStamp) {
    # Copy source -> target atomically (temp then move), verify non-empty,
    # refresh the .delivered stamp.
    New-Item -ItemType Directory -Path $closeoutDir -Force | Out-Null
    # Temp in the SAME dir as the target so the move is a same-volume rename
    # (atomic), not a cross-volume copy+delete that could leave a torn file.
    $tmp = Join-Path $closeoutDir ('.SKILL.tmp.' + [guid]::NewGuid().ToString('N'))
    Copy-Item -LiteralPath $closeoutSource -Destination $tmp -Force
    Move-Item -LiteralPath $tmp -Destination $closeoutTarget -Force
    if ((Get-Item -LiteralPath $closeoutTarget).Length -le 0) {
        throw "Closeout install wrote an empty file at $closeoutTarget"
    }
    Set-Content -Path $closeoutStamp -Value (Get-NormalizedHash $closeoutSource) -Encoding utf8 -NoNewline
}

# ---- run ----------------------------------------------------------------

# LOCKSTEP PARITY (bootstrap.ps1 <-> bootstrap.sh): these two scripts MUST behave
# identically. Change one => change the other. Operations that must stay in sync:
#   - managed surfaces: MEMORY.md preamble, CLAUDE.md section, REGISTRY.md preamble
#   - closeout skill (opt-in): install / uninstall / whole-file drift report /
#     .delivered stamp / symlink-junction refusal / -Force + re-install resync
# Verify BOTH scripts after a change: `pwsh -NoProfile -File test/verify.ps1` AND
# `bash test/verify.sh` (or the manual recipe in BOOTSTRAP.md).
$summary        = @()
$driftReported  = $false

# 1. Memory directory
if (-not (Test-Path $memoryDir)) {
    if ($PSCmdlet.ShouldProcess($memoryDir, 'create directory')) {
        New-Item -ItemType Directory -Path $memoryDir -Force | Out-Null
    }
    $summary += "  created   $memoryDir"
} else {
    $summary += "  exists    $memoryDir"
}

# 2. MEMORY.md
$templateLines   = Read-NormalizedLines $template
$templatePreamble = Get-PreambleRegion $templateLines '^## Entries\s*$'
if ($null -eq $templatePreamble) {
    throw "Template at $template is missing the '## Entries' marker; cannot proceed."
}

if (-not (Test-Path $memoryIndex)) {
    if ($PSCmdlet.ShouldProcess($memoryIndex, 'seed MEMORY.md from template')) {
        Copy-Item -Path $template -Destination $memoryIndex
    }
    $summary += "  created   $memoryIndex (from template)"
} else {
    $liveLines    = Read-NormalizedLines $memoryIndex
    $livePreamble = Get-PreambleRegion $liveLines '^## Entries\s*$'

    if ($null -eq $livePreamble) {
        $summary += "  WARN      $memoryIndex (missing '## Entries' marker; refusing to touch)"
    } elseif ($livePreamble.Preamble -eq $templatePreamble.Preamble) {
        $summary += "  exists    $memoryIndex (preamble matches template)"
    } elseif ($Force) {
        if ($PSCmdlet.ShouldProcess($memoryIndex, 'replace MEMORY.md preamble with canonical')) {
            $tailLines = $liveLines[$livePreamble.MarkerIdx..($liveLines.Count - 1)]
            $newLines = @($templatePreamble.PreambleLines) + @('') + @($tailLines)
            Write-File $memoryIndex $newLines
        }
        $summary += "  synced    $memoryIndex (preamble replaced)"
    } else {
        $summary += "  DRIFT     $memoryIndex (preamble differs from template; re-run with -Force to sync)"
        Show-Diff 'MEMORY.md preamble' $livePreamble.Preamble $templatePreamble.Preamble
        $driftReported = $true
    }
}

# 3 + 4. CLAUDE.md
$snippetLines = Read-NormalizedLines $snippet
$canonSection = $snippetLines -join "`n"

if (-not (Test-Path $claudeMd)) {
    if ($PSCmdlet.ShouldProcess($claudeMd, 'create with header and section')) {
        $headerLines = @(
            '# Global CLAUDE.md',
            '',
            'Personal preferences and conventions that apply across all projects.',
            "Project-specific guidance lives in each repo's CLAUDE.md.",
            ''
        )
        $newLines = $headerLines + $snippetLines
        Write-File $claudeMd $newLines
    }
    $summary += "  created   $claudeMd (with minimal header + section)"
} else {
    $liveLines   = Read-NormalizedLines $claudeMd
    $liveSection = Get-ClaudeMdSection $liveLines

    if ($null -eq $liveSection) {
        if ($PSCmdlet.ShouldProcess($claudeMd, 'append cross-project memory section')) {
            $newLines = $liveLines + @('') + $snippetLines
            Write-File $claudeMd $newLines
        }
        $summary += "  appended  cross-project memory section to $claudeMd"
    } elseif ($liveSection.Section -eq $canonSection) {
        $summary += "  exists    $claudeMd (section matches canonical snippet)"
    } elseif ($Force) {
        if ($PSCmdlet.ShouldProcess($claudeMd, 'replace cross-project memory section')) {
            $beforeLines = if ($liveSection.StartIdx -gt 0) { $liveLines[0..($liveSection.StartIdx - 1)] } else { @() }
            $afterLines  = if ($liveSection.EndIdx -lt $liveLines.Count) { $liveLines[$liveSection.EndIdx..($liveLines.Count - 1)] } else { @() }
            # Trim trailing blanks from before-block (we'll add one separator)
            while ($beforeLines.Count -gt 0 -and $beforeLines[-1] -eq '') {
                $beforeLines = $beforeLines[0..($beforeLines.Count - 2)]
            }
            # Trim leading blanks from after-block (we'll add one separator)
            while ($afterLines.Count -gt 0 -and $afterLines[0] -eq '') {
                if ($afterLines.Count -eq 1) { $afterLines = @() } else { $afterLines = $afterLines[1..($afterLines.Count - 1)] }
            }
            $newLines = @()
            if ($beforeLines.Count -gt 0) { $newLines += $beforeLines + @('') }
            $newLines += $snippetLines
            if ($afterLines.Count -gt 0) { $newLines += @('') + $afterLines }
            Write-File $claudeMd $newLines
        }
        $summary += "  synced    $claudeMd (section replaced)"
    } else {
        $summary += "  DRIFT     $claudeMd (section differs from snippet; re-run with -Force to sync)"
        Show-Diff 'CLAUDE.md cross-project section' $liveSection.Section $canonSection
        $driftReported = $true
    }
}

# 5. Hooks registry. Markdown ledger ONLY -- this is never a hook and never
#    mutates settings.json; the scaffold installs no hooks (see HOOKS.md).
if (-not (Test-Path $hooksDir)) {
    if ($PSCmdlet.ShouldProcess($hooksDir, 'create directory')) {
        New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null
    }
    $summary += "  created   $hooksDir"
} else {
    $summary += "  exists    $hooksDir"
}

$registryTemplateLines    = Read-NormalizedLines $registryTemplate
$registryTemplatePreamble = Get-PreambleRegion $registryTemplateLines '^## Registered hooks\s*$'
if ($null -eq $registryTemplatePreamble) {
    throw "Registry template at $registryTemplate is missing the '## Registered hooks' marker; cannot proceed."
}

if (-not (Test-Path $registry)) {
    if ($PSCmdlet.ShouldProcess($registry, 'seed REGISTRY.md from template')) {
        Copy-Item -Path $registryTemplate -Destination $registry
    }
    $summary += "  created   $registry (from template)"
} else {
    $liveRegLines    = Read-NormalizedLines $registry
    $liveRegPreamble = Get-PreambleRegion $liveRegLines '^## Registered hooks\s*$'

    if ($null -eq $liveRegPreamble) {
        $summary += "  WARN      $registry (missing '## Registered hooks' marker; refusing to touch)"
    } elseif ($liveRegPreamble.Preamble -eq $registryTemplatePreamble.Preamble) {
        $summary += "  exists    $registry (preamble matches template)"
    } elseif ($Force) {
        if ($PSCmdlet.ShouldProcess($registry, 'replace REGISTRY.md preamble with canonical')) {
            $tailLines = $liveRegLines[$liveRegPreamble.MarkerIdx..($liveRegLines.Count - 1)]
            $newLines = @($registryTemplatePreamble.PreambleLines) + @('') + @($tailLines)
            Write-File $registry $newLines
        }
        $summary += "  synced    $registry (preamble replaced)"
    } else {
        $summary += "  DRIFT     $registry (preamble differs from template; re-run with -Force to sync)"
        Show-Diff 'REGISTRY.md preamble' $liveRegPreamble.Preamble $registryTemplatePreamble.Preamble
        $driftReported = $true
    }
}

# 6. Closeout skill (opt-in) -- whole-file managed surface; mirrors the
#    --install-closeout / -InstallCloseout block in bootstrap.sh exactly.
#    Owns the whole SKILL.md, installs only on -InstallCloseout, re-syncs only
#    on demand (-Force, or -InstallCloseout re-run for an unmodified-but-stale
#    copy). The .delivered stamp tells a stale-but-untouched copy from an edited
#    one. Never writes through a symlink/junction.
if ($UninstallCloseout) {
    if (Test-IsReparsePoint $closeoutDir) {
        # Remove only the junction/symlink itself, never recurse into its target.
        if ($PSCmdlet.ShouldProcess($closeoutDir, 'remove closeout symlink/junction')) {
            (Get-Item -LiteralPath $closeoutDir -Force).Delete()
        }
        $summary += "  removed   $closeoutDir (closeout symlink/junction removed; target left untouched)"
    } elseif ((Test-Path -LiteralPath $closeoutTarget) -or (Test-Path -LiteralPath $closeoutDir)) {
        # Remove only what we installed; rmdir only if empty so we never clobber
        # files the user added under the skill directory.
        if ($PSCmdlet.ShouldProcess($closeoutTarget, 'uninstall closeout skill')) {
            Remove-Item -LiteralPath $closeoutTarget -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $closeoutStamp  -Force -ErrorAction SilentlyContinue
            if ((Test-Path -LiteralPath $closeoutDir) -and -not (Get-ChildItem -LiteralPath $closeoutDir -Force)) {
                Remove-Item -LiteralPath $closeoutDir -Force
            }
        }
        $summary += "  removed   $closeoutTarget (closeout uninstalled)"
    } else {
        $summary += "  skip      closeout skill (not installed)"
    }
} elseif ((Test-IsReparsePoint $closeoutDir) -or (Test-IsReparsePoint $closeoutTarget)) {
    $summary += "  WARN      $closeoutDir is a symlink/junction; not managing it. Remove it first to let bootstrap manage a copy."
} elseif (-not (Test-Path -LiteralPath $closeoutTarget)) {
    if ($InstallCloseout) {
        if (-not (Test-Path $closeoutSource)) { throw "Closeout source not found at $closeoutSource -- run from a clone of the repo." }
        if ($PSCmdlet.ShouldProcess($closeoutTarget, 'install closeout skill')) {
            Install-Closeout $closeoutSource $closeoutDir $closeoutTarget $closeoutStamp
        }
        $summary += "  created   $closeoutTarget (closeout installed)"
    } else {
        $summary += "  skip      closeout skill (not installed; -InstallCloseout to add)"
    }
} else {
    if (-not (Test-Path $closeoutSource)) { throw "Closeout source not found at $closeoutSource -- run from a clone of the repo." }
    $srcHash  = Get-NormalizedHash $closeoutSource
    $instHash = Get-NormalizedHash $closeoutTarget
    if ($srcHash -eq $instHash) {
        $summary += "  exists    $closeoutTarget (in sync)"
    } else {
        $stampHash = ''
        if (Test-Path -LiteralPath $closeoutStamp) { $stampHash = (Get-Content -LiteralPath $closeoutStamp -Raw).Trim() }
        if ($stampHash -ne '' -and $stampHash -eq $instHash) {
            # Unmodified since we wrote it, but the repo moved forward.
            if ($InstallCloseout -or $Force) {
                if ($PSCmdlet.ShouldProcess($closeoutTarget, 'update closeout skill to current version')) {
                    Install-Closeout $closeoutSource $closeoutDir $closeoutTarget $closeoutStamp
                }
                $summary += "  synced    $closeoutTarget (updated to current version)"
            } else {
                $summary += "  DRIFT     $closeoutTarget (newer version available; your copy is unmodified -- -InstallCloseout or -Force to update)"
                $driftReported = $true
            }
        } else {
            # User-edited (or no stamp to prove otherwise): never clobber without -Force.
            if ($Force) {
                if ($PSCmdlet.ShouldProcess($closeoutTarget, 'overwrite modified closeout skill')) {
                    Install-Closeout $closeoutSource $closeoutDir $closeoutTarget $closeoutStamp
                }
                $summary += "  synced    $closeoutTarget (overwrote modified copy)"
            } else {
                $summary += "  DRIFT     $closeoutTarget (differs and looks edited; -Force overwrites your changes)"
                $driftReported = $true
            }
        }
    }
}

Write-Host ''
Write-Host 'Bootstrap complete.'
Write-Host ''
Write-Host 'Summary:'
$summary | ForEach-Object { Write-Host $_ }
Write-Host ''
if ($driftReported) {
    Write-Host 'Drift detected. Re-run with -Force to overwrite the drifted regions with the'
    Write-Host 'canonical content shipped in this repo. Hand-customisations inside those'
    Write-Host 'regions will be lost; customisations outside them are preserved.'
    Write-Host ''
}
Write-Host 'Next steps:'
Write-Host '  - Open ~/.claude/CLAUDE.md and confirm the section reads well.'
Write-Host '  - Optionally seed ~/.claude/memory/user_identity.md (see BOOTSTRAP.md).'
Write-Host '  - Save memories as you work; the system fills itself.'
