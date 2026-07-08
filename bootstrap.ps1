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
    5. Seeds ~/.claude/hooks/REGISTRY.md (a hooks ledger) from
       REGISTRY.md.template if absent; otherwise drift-checks its preamble
       (above '## Registered hooks').
    6. Installs the memory-loader hook (default ON): copies
       hooks/memory-loader.sh to ~/.claude/hooks/ and registers it in
       ~/.claude/settings.json under SessionStart + SubagentStart. This is
       the ONE place bootstrap touches settings.json: the loader's two
       registration blocks, merged with a real JSON parser; every other
       key, event, and entry is preserved. The loader injects the
       '## Entries' of ~/.claude/memory/MEMORY.md into main sessions and
       non-lean subagents (the script itself skips Explore and Plan).
       -NoLoader skips this run; -UninstallLoader removes it all and opts
       out of future bare runs; -InstallLoader opts back in. Also keeps one
       bootstrap-managed row (first cell 'memory-loader') in the ledger.
    7. ONLY with -InstallSkills: copies the bundled skills (closeout,
       memory-sweep) to ~/.claude/skills/<name>/SKILL.md (whole-file
       managed surfaces, each with a .delivered stamp). Default off. Pass
       -Skills <names> to select a subset; omit for all. -UninstallSkills
       removes them.

  Drift detection means the file's managed region differs from the
  canonical content shipped in this repo. By default, drift is reported
  with a diff but not corrected. Re-run with -Force to rewrite drifted
  regions with the canonical content. Hand-customisations inside those
  regions will be lost; customisations outside them are preserved.
  (One exception: an installed memory-loader.sh whose stamp proves it was
  never hand-edited auto-updates on a bare run -- load-bearing
  infrastructure, no user content at risk.)

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
    [switch]$NoLoader,
    [switch]$InstallLoader,
    [switch]$UninstallLoader,
    [switch]$InstallSkills,
    [switch]$UninstallSkills,
    [string[]]$Skills
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
$settingsJson     = Join-Path $claudeHome 'settings.json'
$loaderSource     = Join-Path $repoRoot (Join-Path 'hooks' 'memory-loader.sh')
$loaderTarget     = Join-Path $hooksDir 'memory-loader.sh'
$loaderStamp      = Join-Path $hooksDir '.memory-loader.delivered'
$loaderOptout     = Join-Path $hooksDir '.memory-loader.optout'
# The registration command string. Absolute path (HOOKS.md: ~ is not reliably
# expanded in settings.json command strings); double quotes so paths with
# spaces survive every shell; forward slashes so the same string comes out of
# bootstrap.ps1 and bootstrap.sh (which uses cygpath -m) on the same machine.
$loaderCmd        = 'bash "' + ($loaderTarget -replace '\\', '/') + '"'
$loaderEvents     = @('SessionStart', 'SubagentStart')
# Flag-neutral so bootstrap.sh and bootstrap.ps1 emit the identical row.
$loaderRegistryRow = '| memory-loader | SessionStart + SubagentStart (no matcher) | main-session start/resume/clear/compact + non-lean subagent spawn (script skips Explore, Plan) | the ## Entries section of ~/.claude/memory/MEMORY.md | the index itself | harness injects cross-project memory natively, or uninstall via bootstrap (--uninstall-loader / -UninstallLoader) |'
$skillsDir        = Join-Path $claudeHome 'skills'
# Bundled skills shipped by this repo, installed on demand (see -InstallSkills).
# Add a skill by dropping skills\<name>\SKILL.md and listing <name> here.
$bundledSkills    = @('closeout', 'memory-sweep')

if (-not (Test-Path $template)) {
    throw "Template not found at $template -- run this script from a clone of the claude-global-memory repo."
}
if (-not (Test-Path $snippet)) {
    throw "Snippet not found at $snippet -- run this script from a clone of the claude-global-memory repo."
}
if (-not (Test-Path $registryTemplate)) {
    throw "Registry template not found at $registryTemplate -- run this script from a clone of the claude-global-memory repo."
}
if (-not (Test-Path $loaderSource)) {
    throw "Loader hook source not found at $loaderSource -- run this script from a clone of the claude-global-memory repo."
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

function Install-Skill($source, $dir, $target, $stamp) {
    # Copy source -> target atomically (temp then move), verify non-empty,
    # refresh the .delivered stamp.
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    # Temp in the SAME dir as the target so the move is a same-volume rename
    # (atomic), not a cross-volume copy+delete that could leave a torn file.
    $tmp = Join-Path $dir ('.SKILL.tmp.' + [guid]::NewGuid().ToString('N'))
    Copy-Item -LiteralPath $source -Destination $tmp -Force
    Move-Item -LiteralPath $tmp -Destination $target -Force
    if ((Get-Item -LiteralPath $target).Length -le 0) {
        throw "Skill install wrote an empty file at $target"
    }
    Set-Content -Path $stamp -Value (Get-NormalizedHash $source) -Encoding utf8 -NoNewline
}

function Test-SkillSelected($name) {
    # Empty/absent -Skills filter = all bundled skills.
    if (-not $Skills -or $Skills.Count -eq 0) { return $true }
    return ($Skills -contains $name)
}

# ---- memory-loader helpers -------------------------------------------------
# The settings.json merge NEVER text-munges: parse, mutate, re-serialize,
# round-trip-validate, atomic rename. An unparseable file is never touched.
# Mirrors the settings_merge python helper in bootstrap.sh.

function Read-SettingsState {
    # @{ Status = 'invalid' } or @{ Status = 'ok'; Data = <obj or $null> }
    if (-not (Test-Path -LiteralPath $settingsJson)) { return @{ Status = 'ok'; Data = $null } }
    $raw = Get-Content -LiteralPath $settingsJson -Raw
    if ($null -eq $raw -or $raw.Trim() -eq '') { return @{ Status = 'ok'; Data = $null } }
    try { $d = ConvertFrom-Json $raw } catch { return @{ Status = 'invalid' } }
    if ($d -isnot [pscustomobject]) { return @{ Status = 'invalid' } }
    return @{ Status = 'ok'; Data = $d }
}

function Test-OursEntry($entry) {
    # An entry is ours if any of its hook commands references the loader path
    # (either slash style, in case of an old hand-added registration).
    if ($null -eq $entry) { return $false }
    $hs = $entry.hooks
    if ($null -eq $hs) { return $false }
    foreach ($h in @($hs)) {
        if ($null -eq $h -or $null -eq $h.command) { continue }
        if ((($h.command) -replace '\\', '/') -like '*/hooks/memory-loader.sh*') { return $true }
    }
    return $false
}

function Test-CanonicalEntry($entry) {
    if ($null -eq $entry) { return $false }
    $names = @($entry.PSObject.Properties.Name)
    if ($names.Count -ne 1 -or $names[0] -ne 'hooks') { return $false }
    $hs = @($entry.hooks)
    if ($hs.Count -ne 1) { return $false }
    $h = $hs[0]
    $hn = (@($h.PSObject.Properties.Name) | Sort-Object) -join ','
    if ($hn -ne 'command,timeout,type') { return $false }
    return (($h.type -eq 'command') -and ($h.command -eq $loaderCmd) -and ($h.timeout -eq 10))
}

function New-CanonicalEntry {
    return [pscustomobject]@{
        hooks = @([pscustomobject]@{ type = 'command'; command = $loaderCmd; timeout = 10 })
    }
}

function Get-LoaderRegistrationStatus {
    # ok | absent | partial | drift | invalid (same tokens as bootstrap.sh).
    $st = Read-SettingsState
    if ($st.Status -eq 'invalid') { return 'invalid' }
    if ($null -eq $st.Data) { return 'absent' }
    $hooks = $st.Data.hooks
    if ($null -ne $hooks -and $hooks -isnot [pscustomobject]) { return 'invalid' }
    $states = @()
    foreach ($ev in $loaderEvents) {
        $arr = @()
        if ($null -ne $hooks -and $hooks.PSObject.Properties[$ev]) {
            $v = $hooks.$ev
            if ($null -ne $v -and $v -isnot [System.Array]) { return 'invalid' }
            if ($null -ne $v) { $arr = @($v) }
        }
        $ours = @($arr | Where-Object { Test-OursEntry $_ })
        if ($ours.Count -eq 0) { $states += 'absent' }
        elseif ($ours.Count -eq 1 -and (Test-CanonicalEntry $ours[0])) { $states += 'ok' }
        else { $states += 'drift' }
    }
    if ($states -contains 'drift') { return 'drift' }
    if (@($states | Where-Object { $_ -eq 'ok' }).Count -eq 2) { return 'ok' }
    if (@($states | Where-Object { $_ -eq 'absent' }).Count -eq 2) { return 'absent' }
    return 'partial'
}

function Write-SettingsFile($data) {
    $json = ConvertTo-Json -InputObject $data -Depth 32
    ConvertFrom-Json $json | Out-Null   # round-trip check before touching the file
    $tmp = Join-Path $claudeHome ('.settings.tmp.' + [guid]::NewGuid().ToString('N'))
    [System.IO.File]::WriteAllText($tmp, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $settingsJson -Force
}

function Set-LoaderRegistration {
    # Ensure both canonical blocks exist; caller has already gated on status.
    $st = Read-SettingsState
    $data = $st.Data
    if ($null -eq $data) { $data = [pscustomobject]@{} }
    $hooksProp = $data.PSObject.Properties['hooks']
    if ($null -eq $hooksProp -or $null -eq $data.hooks -or $data.hooks -isnot [pscustomobject]) {
        if ($hooksProp) { $data.PSObject.Properties.Remove('hooks') }
        $data | Add-Member -MemberType NoteProperty -Name 'hooks' -Value ([pscustomobject]@{})
    }
    $hooks = $data.hooks
    foreach ($ev in $loaderEvents) {
        $arr = @()
        if ($hooks.PSObject.Properties[$ev] -and $null -ne $hooks.$ev) { $arr = @($hooks.$ev) }
        $ours = @($arr | Where-Object { Test-OursEntry $_ })
        if ($ours.Count -eq 1 -and (Test-CanonicalEntry $ours[0]) -and $hooks.PSObject.Properties[$ev]) { continue }
        $kept = @($arr | Where-Object { -not (Test-OursEntry $_) })
        $new = @($kept) + @(New-CanonicalEntry)
        if ($hooks.PSObject.Properties[$ev]) { $hooks.$ev = $new }
        else { $hooks | Add-Member -MemberType NoteProperty -Name $ev -Value $new }
    }
    Write-SettingsFile $data
}

function Remove-LoaderRegistration {
    $st = Read-SettingsState
    if ($st.Status -eq 'invalid') { return }
    $data = $st.Data
    if ($null -eq $data) { return }
    if (-not $data.PSObject.Properties['hooks'] -or $data.hooks -isnot [pscustomobject]) { return }
    $hooks = $data.hooks
    $changed = $false
    foreach ($ev in $loaderEvents) {
        if (-not $hooks.PSObject.Properties[$ev] -or $null -eq $hooks.$ev) { continue }
        $arr = @($hooks.$ev)
        $kept = @($arr | Where-Object { -not (Test-OursEntry $_) })
        if ($kept.Count -eq $arr.Count) { continue }
        $changed = $true
        if ($kept.Count -eq 0) { $hooks.PSObject.Properties.Remove($ev) }
        else { $hooks.$ev = $kept }
    }
    if ($changed) {
        if (@($hooks.PSObject.Properties).Count -eq 0) { $data.PSObject.Properties.Remove('hooks') }
        Write-SettingsFile $data
    }
}

function Test-LoaderRegistryRowPresent {
    if (-not (Test-Path -LiteralPath $registry)) { return $false }
    $hit = Get-Content -LiteralPath $registry | Where-Object { $_ -match '^\| memory-loader \|' } | Select-Object -First 1
    return [bool]$hit
}

# ---- run ----------------------------------------------------------------

# LOCKSTEP PARITY (bootstrap.ps1 <-> bootstrap.sh): these two scripts MUST behave
# identically. Change one => change the other. Operations that must stay in sync:
#   - managed surfaces: MEMORY.md preamble, CLAUDE.md section, REGISTRY.md preamble
#   - memory-loader (default-on): script install + stamp + auto-update of
#     unmodified-stale copies, the two-event settings.json merge/uninstall,
#     the ledger row, and the sticky opt-out
#   - bundled skills (opt-in): install / uninstall / whole-file drift report /
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

# 5. Hooks registry. Markdown ledger; the memory-loader (step 6) is the only
#    hook this scaffold installs (see HOOKS.md).
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

# 6. Memory-loader hook (default ON; see HOOKS.md "The load-bearing exception").
#    Mirrors the manage_loader block in bootstrap.sh exactly. Three surfaces:
#    (a) ~/.claude/hooks/memory-loader.sh -- whole-file surface + .delivered
#        stamp; an unmodified-but-stale copy auto-updates on a bare run (the
#        bare run is the loader's install gesture and the stamp proves no
#        user edit is lost); hand-edited copies still require -Force.
#    (b) ~/.claude/settings.json -- the ONE place bootstrap touches it: the
#        loader's two registration blocks; everything else is preserved and
#        an unparseable file is never touched.
#    (c) ~/.claude/hooks/REGISTRY.md -- one bootstrap-managed row (first cell
#        'memory-loader'); other rows are never touched.
#    -UninstallLoader is sticky via .memory-loader.optout so a later bare
#    re-run does not silently resurrect the hook; -InstallLoader re-enables;
#    -NoLoader skips loader management for this run only.
function Manage-Loader {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param()

    if ($UninstallLoader) {
        if (Test-Path -LiteralPath $settingsJson) {
            $status = Get-LoaderRegistrationStatus
            if ($status -eq 'invalid') {
                $script:summary += "  WARN      $settingsJson (not valid JSON; remove the memory-loader registration by hand, see BOOTSTRAP.md)"
            } elseif ($status -ne 'absent') {
                if ($PSCmdlet.ShouldProcess($settingsJson, 'remove memory-loader registration')) {
                    Remove-LoaderRegistration
                }
                $script:summary += "  removed   memory-loader registration from $settingsJson"
            }
        }
        if (Test-IsReparsePoint $loaderTarget) {
            if ($PSCmdlet.ShouldProcess($loaderTarget, 'remove memory-loader symlink/junction')) {
                (Get-Item -LiteralPath $loaderTarget -Force).Delete()
            }
            $script:summary += "  removed   $loaderTarget (memory-loader symlink/junction removed; target left untouched)"
        } elseif (Test-Path -LiteralPath $loaderTarget) {
            if ($PSCmdlet.ShouldProcess($loaderTarget, 'uninstall memory-loader hook')) {
                Remove-Item -LiteralPath $loaderTarget -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $loaderStamp  -Force -ErrorAction SilentlyContinue
            }
            $script:summary += "  removed   $loaderTarget (memory-loader uninstalled)"
        } else {
            $script:summary += "  skip      memory-loader hook (not installed)"
        }
        if (Test-LoaderRegistryRowPresent) {
            if ($PSCmdlet.ShouldProcess($registry, 'remove memory-loader row')) {
                $regLines = @(Get-Content -LiteralPath $registry) | Where-Object { $_ -notmatch '^\| memory-loader \|' }
                Write-File $registry $regLines
            }
            $script:summary += "  removed   memory-loader row from $registry"
        }
        if ($PSCmdlet.ShouldProcess($loaderOptout, 'record loader opt-out')) {
            New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null
            Set-Content -Path $loaderOptout -Value '' -NoNewline
        }
        $script:summary += "  created   $loaderOptout (bare re-runs stay opted out; -InstallLoader re-enables)"
        return
    }

    if ($NoLoader) {
        $script:summary += "  skip      memory-loader hook (-NoLoader)"
        return
    }

    if (Test-Path -LiteralPath $loaderOptout) {
        if ($InstallLoader) {
            if ($PSCmdlet.ShouldProcess($loaderOptout, 'clear loader opt-out')) {
                Remove-Item -LiteralPath $loaderOptout -Force
            }
        } else {
            $script:summary += "  skip      memory-loader hook (opted out; -InstallLoader to re-enable)"
            return
        }
    }

    if (Test-IsReparsePoint $loaderTarget) {
        $script:summary += "  WARN      $loaderTarget is a symlink/junction; not managing it. Remove it first to let bootstrap manage a copy."
        return
    }

    # (a) the hook script itself
    if (-not (Test-Path -LiteralPath $loaderTarget)) {
        if ($PSCmdlet.ShouldProcess($loaderTarget, 'install memory-loader hook')) {
            Install-Skill $loaderSource $hooksDir $loaderTarget $loaderStamp
        }
        $script:summary += "  created   $loaderTarget (memory-loader hook installed)"
    } else {
        $srcHash  = Get-NormalizedHash $loaderSource
        $instHash = Get-NormalizedHash $loaderTarget
        if ($srcHash -eq $instHash) {
            $script:summary += "  exists    $loaderTarget (in sync)"
        } else {
            $stampHash = ''
            if (Test-Path -LiteralPath $loaderStamp) { $stampHash = (Get-Content -LiteralPath $loaderStamp -Raw).Trim() }
            if ($stampHash -ne '' -and $stampHash -eq $instHash) {
                # Unmodified since we wrote it: auto-update (see block comment).
                if ($PSCmdlet.ShouldProcess($loaderTarget, 'update memory-loader hook to current version')) {
                    Install-Skill $loaderSource $hooksDir $loaderTarget $loaderStamp
                }
                $script:summary += "  synced    $loaderTarget (updated to current version)"
            } elseif ($Force) {
                if ($PSCmdlet.ShouldProcess($loaderTarget, 'overwrite modified memory-loader hook')) {
                    Install-Skill $loaderSource $hooksDir $loaderTarget $loaderStamp
                }
                $script:summary += "  synced    $loaderTarget (overwrote modified copy)"
            } else {
                $script:summary += "  DRIFT     $loaderTarget (differs and looks edited; -Force overwrites your changes)"
                $script:driftReported = $true
            }
        }
    }

    # (b) settings.json registrations
    $status = Get-LoaderRegistrationStatus
    switch ($status) {
        'ok' {
            $script:summary += "  exists    $settingsJson (memory-loader registered)"
        }
        'invalid' {
            $script:summary += "  WARN      $settingsJson (not valid JSON; not touching it -- add the memory-loader registration by hand, see BOOTSTRAP.md)"
        }
        'drift' {
            if ($Force) {
                if ($PSCmdlet.ShouldProcess($settingsJson, 'replace memory-loader registration')) {
                    Set-LoaderRegistration
                }
                $script:summary += "  synced    $settingsJson (memory-loader registration replaced)"
            } else {
                $script:summary += "  DRIFT     $settingsJson (memory-loader registration differs from canonical; re-run with -Force to sync)"
                $script:driftReported = $true
            }
        }
        default {
            $existed = Test-Path -LiteralPath $settingsJson
            if ($PSCmdlet.ShouldProcess($settingsJson, 'register memory-loader (SessionStart + SubagentStart)')) {
                Set-LoaderRegistration
            }
            if ($existed) {
                $script:summary += "  appended  memory-loader registration to $settingsJson"
            } else {
                $script:summary += "  created   $settingsJson (memory-loader registered under SessionStart + SubagentStart)"
            }
        }
    }

    # (c) ledger row
    if ((Test-Path -LiteralPath $registry) -and -not (Test-LoaderRegistryRowPresent)) {
        $regLines = @(Get-Content -LiteralPath $registry)
        if (@($regLines | Where-Object { $_ -match '^## Registered hooks\s*$' }).Count -gt 0) {
            if ($PSCmdlet.ShouldProcess($registry, 'append memory-loader row')) {
                Add-Content -Path $registry -Value $loaderRegistryRow
            }
            $script:summary += "  appended  memory-loader row to $registry"
        }
    }
}

Manage-Loader

# 7. Bundled skills (opt-in) -- whole-file managed surfaces; mirrors the
#    --install-skills / --uninstall-skills block in bootstrap.sh exactly.
#    Each owns its whole SKILL.md, installs only on -InstallSkills, re-syncs only
#    on demand (-Force, or -InstallSkills re-run for an unmodified-but-stale
#    copy). The .delivered stamp tells a stale-but-untouched copy from an edited
#    one. Never writes through a symlink/junction. Runs for every skill in
#    $bundledSkills via Manage-Skill (advanced function so -WhatIf propagates).
function Manage-Skill {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param($name)
    $dir    = Join-Path $skillsDir $name
    $target = Join-Path $dir 'SKILL.md'
    $stamp  = Join-Path $dir '.delivered'
    $source = Join-Path $repoRoot (Join-Path 'skills' (Join-Path $name 'SKILL.md'))

    if ($UninstallSkills -and (Test-SkillSelected $name)) {
        if (Test-IsReparsePoint $dir) {
            # Remove only the junction/symlink itself, never recurse into its target.
            if ($PSCmdlet.ShouldProcess($dir, "remove $name symlink/junction")) {
                (Get-Item -LiteralPath $dir -Force).Delete()
            }
            $script:summary += "  removed   $dir ($name symlink/junction removed; target left untouched)"
        } elseif ((Test-Path -LiteralPath $target) -or (Test-Path -LiteralPath $dir)) {
            # Remove only what we installed; rmdir only if empty so we never clobber
            # files the user added under the skill directory.
            if ($PSCmdlet.ShouldProcess($target, "uninstall $name skill")) {
                Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $stamp  -Force -ErrorAction SilentlyContinue
                if ((Test-Path -LiteralPath $dir) -and -not (Get-ChildItem -LiteralPath $dir -Force)) {
                    Remove-Item -LiteralPath $dir -Force
                }
            }
            $script:summary += "  removed   $target ($name uninstalled)"
        } else {
            $script:summary += "  skip      $name skill (not installed)"
        }
        return
    }

    if ((Test-IsReparsePoint $dir) -or (Test-IsReparsePoint $target)) {
        $script:summary += "  WARN      $dir is a symlink/junction; not managing it. Remove it first to let bootstrap manage a copy."
        return
    }

    if (-not (Test-Path $source)) { throw "Skill source not found at $source -- run from a clone of the repo." }

    if (-not (Test-Path -LiteralPath $target)) {
        if ($InstallSkills -and (Test-SkillSelected $name)) {
            if ($PSCmdlet.ShouldProcess($target, "install $name skill")) {
                Install-Skill $source $dir $target $stamp
            }
            $script:summary += "  created   $target ($name installed)"
        } else {
            $script:summary += "  skip      $name skill (not installed; -InstallSkills to add)"
        }
        return
    }

    $srcHash  = Get-NormalizedHash $source
    $instHash = Get-NormalizedHash $target
    if ($srcHash -eq $instHash) {
        $script:summary += "  exists    $target (in sync)"
        return
    }
    $stampHash = ''
    if (Test-Path -LiteralPath $stamp) { $stampHash = (Get-Content -LiteralPath $stamp -Raw).Trim() }
    if ($stampHash -ne '' -and $stampHash -eq $instHash) {
        # Unmodified since we wrote it, but the repo moved forward.
        if (($InstallSkills -and (Test-SkillSelected $name)) -or $Force) {
            if ($PSCmdlet.ShouldProcess($target, "update $name skill to current version")) {
                Install-Skill $source $dir $target $stamp
            }
            $script:summary += "  synced    $target (updated to current version)"
        } else {
            $script:summary += "  DRIFT     $target (newer version available; your copy is unmodified -- -InstallSkills or -Force to update)"
            $script:driftReported = $true
        }
    } else {
        # User-edited (or no stamp to prove otherwise): never clobber without -Force.
        if ($Force) {
            if ($PSCmdlet.ShouldProcess($target, "overwrite modified $name skill")) {
                Install-Skill $source $dir $target $stamp
            }
            $script:summary += "  synced    $target (overwrote modified copy)"
        } else {
            $script:summary += "  DRIFT     $target (differs and looks edited; -Force overwrites your changes)"
            $script:driftReported = $true
        }
    }
}

foreach ($skillName in $bundledSkills) {
    Manage-Skill $skillName
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
