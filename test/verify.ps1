<#
.SYNOPSIS
  Manual verification harness for bootstrap.ps1.

.DESCRIPTION
  Runs the BOOTSTRAP.md recipe against a throwaway USERPROFILE and asserts the
  managed-surface idempotency + drift-detection + -Force resync contract, the
  memory-loader contract (default-on install, surgical settings.json merge,
  agent-type filter, sticky uninstall), and the full opt-in per-skill matrix
  (closeout + memory-sweep). The repo's manual test convention (no CI, no
  app) made runnable. Run by hand before landing a bootstrap change:

      pwsh -NoProfile -File test/verify.ps1

  LOCKSTEP: keep in sync with test/verify.sh -- the two must assert the same
  cases. bootstrap.ps1 and bootstrap.sh must behave identically.
#>
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$boot = Join-Path $repoRoot 'bootstrap.ps1'
if (-not (Test-Path $boot)) { Write-Error "bootstrap.ps1 not found at $boot"; exit 2 }

$script:pass = 0; $script:fail = 0
$script:TH = $null
function Fresh-Home {
    if ($script:TH -and (Test-Path $script:TH)) { Remove-Item -LiteralPath $script:TH -Recurse -Force -ErrorAction SilentlyContinue }
    $script:TH = Join-Path ([System.IO.Path]::GetTempPath()) ('cgmv-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $script:TH -Force | Out-Null
    $env:USERPROFILE = $script:TH
}
function Run { & pwsh -NoProfile -File $boot @args 2>&1 | Out-String }
function Ok($m)  { $script:pass++; Write-Host "  PASS  $m" }
function No($m)  { $script:fail++; Write-Host "  FAIL  $m" }
function Has($m,$out,$needle)   { if ($out.Contains($needle)) { Ok $m } else { No "$m -- expected to find: $needle" } }
function Hasnt($m,$out,$needle) { if ($out.Contains($needle)) { No "$m -- unexpected: $needle" } else { Ok $m } }
function FileIs($m,$p)   { if (Test-Path -LiteralPath $p) { Ok $m } else { No "$m -- missing: $p" } }
function NoFile($m,$p)   { if (Test-Path -LiteralPath $p) { No "$m -- should be gone: $p" } else { Ok $m } }

# Mirror bootstrap.ps1's Read-NormalizedLines + Get-NormalizedHash to forge a stamp.
function NHash($p) {
    $t = ((Get-Content $p -Raw) -replace "`r`n","`n")
    $l = $t -split "`n" | ForEach-Object { $_ -replace '\s+$','' }
    while ($l.Count -gt 0 -and $l[-1] -eq '') { $l = $l[0..($l.Count-2)] }
    $b = [Text.Encoding]::UTF8.GetBytes(($l -join "`n"))
    return ((([Security.Cryptography.SHA256]::Create()).ComputeHash($b)) | ForEach-Object { $_.ToString('x2') }) -join ''
}
# Derive skill paths from the CURRENT $script:TH on every call -- Fresh-Home
# reassigns $script:TH, so never capture these once.
function SkillDir($name)    { Join-Path $script:TH (Join-Path '.claude\skills' $name) }
function SkillTarget($name) { Join-Path (SkillDir $name) 'SKILL.md' }
function SkillStamp($name)  { Join-Path (SkillDir $name) '.delivered' }
function SkillSrc($name)    { Join-Path $repoRoot (Join-Path 'skills' (Join-Path $name 'SKILL.md')) }

Write-Host "== managed surfaces: fresh install + idempotency =="
Fresh-Home
$out = Run
FileIs "fresh: memory dir created"   (Join-Path $script:TH '.claude\memory')
FileIs "fresh: MEMORY.md created"    (Join-Path $script:TH '.claude\memory\MEMORY.md')
FileIs "fresh: CLAUDE.md created"    (Join-Path $script:TH '.claude\CLAUDE.md')
FileIs "fresh: REGISTRY.md created"  (Join-Path $script:TH '.claude\hooks\REGISTRY.md')
Has    "fresh: closeout skipped (opt-in)" $out "skip      closeout skill (not installed"
Has    "fresh: memory-sweep skipped (opt-in)" $out "skip      memory-sweep skill (not installed"
$out = Run
Hasnt  "idempotent: 2nd run reports no DRIFT" $out "DRIFT"
Hasnt  "idempotent: 2nd run creates nothing"  $out "created"

Write-Host "== managed surfaces: drift detect + -Force resync + entry preservation =="
$mem = Join-Path $script:TH '.claude\memory\MEMORY.md'
Add-Content -Path $mem -Value "`n- [my entry](x.md)"          # below ## Entries, must survive
"TAMPER preamble line", (Get-Content $mem) | Set-Content -Path $mem   # prepend -> preamble drift
$out = Run
Has    "drift: MEMORY.md preamble drift reported" $out "DRIFT"
Has    "drift: drift is on MEMORY.md"             $out "MEMORY.md"
$out = Run -Force
Has    "force: synced reported" $out "synced"
if ((Get-Content $mem -Raw).Contains('[my entry](x.md)')) { Ok "force: user entry below ## Entries preserved" } else { No "force: user entry clobbered" }

# ---- memory-loader (default-on) ----------------------------------------------
# Mirrors the loader block in verify.sh -- keep the two in sync. Hook-EXECUTION
# asserts need a real Git Bash: plain `bash` from PowerShell on Windows resolves
# to the WSL stub. Resolve it from git.exe's install root; SKIP just those
# asserts if absent (all bootstrap/settings asserts still run).
function Get-GitBash {
    if ($env:OS -ne 'Windows_NT') { return 'bash' }
    $candidates = @()
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        $root = Split-Path (Split-Path $git.Source -Parent) -Parent
        $candidates += (Join-Path $root 'bin\bash.exe')
        $candidates += (Join-Path $root 'usr\bin\bash.exe')
    }
    $candidates += 'C:\Program Files\Git\bin\bash.exe'
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    return $null
}
$gitBash = Get-GitBash

function Invoke-LoaderHook($payload) {
    # Forward-slash HOME/script paths so Git Bash resolves them cleanly.
    $oldHome = $env:HOME
    $env:HOME = ($script:TH -replace '\\', '/')
    try {
        $hookPath = ((Join-Path $script:TH '.claude\hooks\memory-loader.sh') -replace '\\', '/')
        return ($payload | & $gitBash $hookPath 2>$null | Out-String).Trim()
    } finally {
        if ($null -ne $oldHome) { $env:HOME = $oldHome } else { Remove-Item Env:HOME -ErrorAction SilentlyContinue }
    }
}

Write-Host "== loader: fresh install (default-on) =="
Fresh-Home
$out = Run
FileIs "loader: script installed"      (Join-Path $script:TH '.claude\hooks\memory-loader.sh')
FileIs "loader: stamp present"         (Join-Path $script:TH '.claude\hooks\.memory-loader.delivered')
FileIs "loader: settings.json created" (Join-Path $script:TH '.claude\settings.json')
Has "loader: registration reported" $out "memory-loader registered under SessionStart + SubagentStart"
Has "loader: ledger row appended"   $out "appended  memory-loader row"
$d = Get-Content (Join-Path $script:TH '.claude\settings.json') -Raw | ConvertFrom-Json
if (@($d.hooks.SessionStart).Count -eq 1 -and @($d.hooks.SubagentStart).Count -eq 1) { Ok "loader: valid JSON, both events, one entry each" } else { No "loader: registration wrong shape" }

Write-Host "== loader: idempotent re-run =="
$out = Run
Hasnt "loader: 2nd run no DRIFT"        $out "DRIFT"
Hasnt "loader: 2nd run creates nothing" $out "created"
$raw = Get-Content (Join-Path $script:TH '.claude\settings.json') -Raw
if (([regex]::Matches($raw, 'memory-loader\.sh')).Count -eq 2) { Ok "loader: no duplicate registrations" } else { No "loader: duplicate registrations in settings.json" }
if (@(Get-Content (Join-Path $script:TH '.claude\hooks\REGISTRY.md') | Where-Object { $_ -match '^\| memory-loader \|' }).Count -eq 1) { Ok "loader: single ledger row" } else { No "loader: duplicate ledger rows" }

Write-Host "== loader: agent-type filter + payload shape =="
Add-Content -Path (Join-Path $script:TH '.claude\memory\MEMORY.md') -Value '- [loader test entry](tools/x.md) -- with "quotes" and a \ backslash'
if ($null -eq $gitBash) {
    Write-Host "  SKIP  loader: hook execution asserts (no Git Bash found)"
} else {
    $o = Invoke-LoaderHook '{"agent_type":"Explore","hook_event_name":"SubagentStart"}'
    if ($o -eq '') { Ok "loader: Explore skipped" } else { No "loader: Explore not skipped" }
    $o = Invoke-LoaderHook '{"agent_type":"Plan","hook_event_name":"SubagentStart"}'
    if ($o -eq '') { Ok "loader: Plan skipped" } else { No "loader: Plan not skipped" }
    $o = Invoke-LoaderHook '{"hook_event_name":"PreToolUse","tool_name":"Bash"}'
    if ($o -eq '') { Ok "loader: other events silent" } else { No "loader: other events not silent" }
    $o = Invoke-LoaderHook '{"agent_type":"general-purpose","hook_event_name":"SubagentStart"}'
    $parsed = $null
    try { $parsed = $o | ConvertFrom-Json } catch {}
    if ($parsed -and $parsed.hookSpecificOutput.hookEventName -eq 'SubagentStart' -and $parsed.hookSpecificOutput.additionalContext.Contains('loader test entry')) {
        Ok "loader: general-purpose gets valid JSON (quotes/backslash escaped)"
    } else { No "loader: general-purpose payload invalid JSON or missing entry" }
    if ($parsed) {
        $lastLine = @($parsed.hookSpecificOutput.additionalContext -split "`n")[-1]
        if ($lastLine.StartsWith('INDEX-END (')) { Ok "loader: payload ends with the INDEX-END sentinel" } else { No "loader: INDEX-END sentinel missing from payload tail" }
    }
    $o = Invoke-LoaderHook '{"hook_event_name":"SessionStart","source":"startup"}'
    if ($o.Contains('Cross-project memory index')) { Ok "loader: SessionStart payload present" } else { No "loader: SessionStart payload missing" }
}

Write-Host "== loader: conf overrides the skip list; broken conf never kills injection =="
$confPath = Join-Path $script:TH '.claude\hooks\memory-loader.conf'
Set-Content -Path $confPath -Value 'skip_agent_types="Explore CustomLean"'   # Set-Content writes CRLF -- on purpose
if ($null -eq $gitBash) {
    Write-Host "  SKIP  loader: conf hook asserts (no Git Bash found)"
} else {
    $o = Invoke-LoaderHook '{"agent_type":"CustomLean","hook_event_name":"SubagentStart"}'
    if ($o -eq '') { Ok "conf: added agent type skipped" } else { No "conf: added agent type not skipped" }
    $o = Invoke-LoaderHook '{"agent_type":"Plan","hook_event_name":"SubagentStart"}'
    if ($o -ne '') { Ok "conf: value replaces the default (Plan now injects)" } else { No "conf: default skip list still active despite conf" }
    $o = Invoke-LoaderHook '{"agent_type":"Explore","hook_event_name":"SubagentStart"}'
    if ($o -eq '') { Ok "conf: kept agent type still skipped" } else { No "conf: kept agent type not skipped" }
    Set-Content -Path $confPath -Value 'this is ( not a conf'
    $o = Invoke-LoaderHook '{"agent_type":"general-purpose","hook_event_name":"SubagentStart"}'
    if ($o -ne '') { Ok "conf: garbage conf ignored, injection alive" } else { No "conf: garbage conf killed injection" }
    $o = Invoke-LoaderHook '{"agent_type":"Explore","hook_event_name":"SubagentStart"}'
    if ($o -eq '') { Ok "conf: garbage conf -> defaults still apply" } else { No "conf: garbage conf broke the defaults" }
}
$confBefore = Get-Content $confPath -Raw
$out = Run
Hasnt "conf: bare re-run stays in sync with conf present" $out "DRIFT"
if ((Get-Content $confPath -Raw) -eq $confBefore) { Ok "conf: bare run leaves conf untouched" } else { No "conf: bare run modified conf" }
Remove-Item -LiteralPath $confPath -Force

Write-Host "== loader: fold -- subagents get above-fold only; strict marker grammar =="
Fresh-Home
Run | Out-Null
$mem = Join-Path $script:TH '.claude\memory\MEMORY.md'
if ($null -eq $gitBash) {
    Write-Host "  SKIP  loader: fold asserts (no Git Bash found)"
} else {
    Add-Content -Path $mem -Value (@('- [above entry](a.md) -- ambient', '<!-- fold -->', '- [below entry](b.md) -- tail', '- [below two](c.md) -- tail2') -join "`n")
    $o = Invoke-LoaderHook '{"agent_type":"general-purpose","hook_event_name":"SubagentStart"}'
    Has   "fold: subagent gets above-fold" $o "above entry"
    Hasnt "fold: subagent does not get below-fold" $o "below entry"
    Has   "fold: segment sentinel carries the pointer" $o "lines below the fold -- read ~/.claude/memory/MEMORY.md"
    $parsed = $null
    try { $parsed = $o | ConvertFrom-Json } catch {}
    if ($parsed -and @($parsed.hookSpecificOutput.additionalContext -split "`n")[-1].StartsWith('INDEX-END (')) {
        Ok "fold: segment sentinel keeps the stable prefix (valid JSON)"
    } else { No "fold: segment sentinel broke the INDEX-END prefix contract" }
    $o = Invoke-LoaderHook '{"hook_event_name":"SessionStart","source":"startup"}'
    Has   "fold: main session still gets the full index" $o "below two"
    Hasnt "fold: literal marker stripped from full payload" $o "fold -->"
    Hasnt "fold: main sentinel not segment-aware" $o "below the fold"
    $o = Invoke-LoaderHook '{"agent_type":"Explore","hook_event_name":"SubagentStart"}'
    if ($o -eq '') { Ok "fold: skip list still wins before fold work" } else { No "fold: Explore not skipped with marker present" }
    $out = Run
    Hasnt "fold: bare re-run reports no DRIFT with marker present" $out "DRIFT"
    Run -Force | Out-Null
    $memRaw = Get-Content $mem -Raw
    if ((@(Get-Content $mem | Where-Object { $_ -eq '<!-- fold -->' }).Count -eq 1) -and $memRaw.Contains('below two')) {
        Ok "fold: marker + tail survive bare and -Force runs"
    } else { No "fold: bootstrap disturbed the marker or tail" }
    Set-Content -Path $mem -Value (@('# H', '', '## Entries', '', '- [inline entry](y.md) -- mentions <!-- fold --> inline', '- [tail entry](t.md) -- t') -join "`n")
    $o = Invoke-LoaderHook '{"agent_type":"general-purpose","hook_event_name":"SubagentStart"}'
    Has   "fold: embedded marker text is data (tail still injected)" $o "tail entry"
    Hasnt "fold: no phantom segment sentinel" $o "below the fold"
    Set-Content -Path $mem -Value (@('# H', '', '## Entries', '', '- [a one](a.md) -- a', '   <!-- fold -->   ', '- [m one](m.md) -- mid', '<!-- fold -->', '- [t one](t.md) -- tail') -join "`n")
    $o = Invoke-LoaderHook '{"agent_type":"general-purpose","hook_event_name":"SubagentStart"}'
    Has   "fold: whitespace-padded marker honored" $o "a one"
    Hasnt "fold: first marker wins (mid withheld)" $o "m one"
    Has   "fold: withheld count spans to the tail" $o "3 lines below the fold"
    Set-Content -Path $mem -Value (@('# H', '', '## Entries', '<!-- fold -->', '- [t only](t.md) -- t') -join "`n")
    $o = Invoke-LoaderHook '{"agent_type":"general-purpose","hook_event_name":"SubagentStart"}'
    Has   "fold: empty above-fold still emits pointer sentinel" $o "INDEX-END (0 lines, 0 bytes;"
    Set-Content -Path $mem -Value (@('# H', '', '## Entries', '', '- [only entry](o.md) -- o', '<!-- fold -->') -join "`n")
    $o = Invoke-LoaderHook '{"agent_type":"general-purpose","hook_event_name":"SubagentStart"}'
    Has   "fold: empty tail withholds nothing" $o "only entry"
    Hasnt "fold: empty tail -> plain sentinel" $o "below the fold"
    $fatTailF = 'y' * 380
    $fatF = @('# H', '', '## Entries', '') + (1..25 | ForEach-Object { "- [af$_](x.md) -- $fatTailF" }) + @('<!-- fold -->', '- [tail z](z.md) -- z')
    Set-Content -Path $mem -Value ($fatF -join "`n")
    $o = Invoke-LoaderHook '{"agent_type":"general-purpose","hook_event_name":"SubagentStart"}'
    Has   "fold: oversized above-fold warns by segment name" $o "ABOVE-FOLD segment alone"
    $degF = @('# H', '', '## Entries', '', '- [head rule](h.md) -- imperative', '<!-- fold -->') + (1..25 | ForEach-Object { "- [tail$_](x.md) -- $fatTailF" })
    Set-Content -Path $mem -Value ($degF -join "`n")
    $o = Invoke-LoaderHook '{"hook_event_name":"SessionStart","source":"startup"}'
    Has   "fold: over-budget main auto-degrades to above-fold" $o "head rule"
    Hasnt "fold: degraded main withholds the tail" $o "tail7"
    Has   "fold: degraded main sentinel carries the pointer" $o "lines below the fold"
    Hasnt "fold: degraded main under-budget segment gets no warning" $o "WARNING"
}

Write-Host "== loader: empty index injects nothing; oversized index warns =="
Fresh-Home
Run | Out-Null
if ($null -eq $gitBash) {
    Write-Host "  SKIP  loader: empty/oversized asserts (no Git Bash found)"
} else {
    $o = Invoke-LoaderHook '{"hook_event_name":"SessionStart","source":"startup"}'
    if ($o -eq '') { Ok "loader: empty Entries -> silent" } else { No "loader: empty Entries injected something" }
    $filler = 1..205 | ForEach-Object { "- [e$_](x.md) -- filler" }
    Add-Content -Path (Join-Path $script:TH '.claude\memory\MEMORY.md') -Value ($filler -join "`n")
    $o = Invoke-LoaderHook '{"hook_event_name":"SessionStart"}'
    if ($o.Contains('lines (cap')) { Ok "loader: line warning past 200 entry lines" } else { No "loader: line warning missing" }
    if ($o.Contains('preview')) { No "loader: byte warning fired on a small-byte index" } else { Ok "loader: byte warning not misfired" }
    # byte budget: few-but-fat lines past ~9KB -> truncation-preview warning wins
    Fresh-Home
    Run | Out-Null
    $fatTail = 'x' * 380
    $fat = 1..25 | ForEach-Object { "- [fat$_](x.md) -- $fatTail" }
    Add-Content -Path (Join-Path $script:TH '.claude\memory\MEMORY.md') -Value ($fat -join "`n")
    $o = Invoke-LoaderHook '{"hook_event_name":"SessionStart"}'
    if ($o.Contains('preview')) { Ok "loader: byte warning past ~9KB of entries" } else { No "loader: byte warning missing" }
}

Write-Host "== loader: preserves unrelated settings.json content =="
Fresh-Home
New-Item -ItemType Directory -Path (Join-Path $script:TH '.claude') -Force | Out-Null
@'
{
  "model": "opus",
  "hooks": {
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo other-hook"}]}],
    "SessionStart": [{"hooks": [{"type": "command", "command": "echo existing-sessionstart"}]}]
  }
}
'@ | Set-Content -Path (Join-Path $script:TH '.claude\settings.json')
$out = Run
Has "loader: appended into existing settings" $out "appended  memory-loader registration"
$d = Get-Content (Join-Path $script:TH '.claude\settings.json') -Raw | ConvertFrom-Json
$ssCmds = @($d.hooks.SessionStart | ForEach-Object { $_.hooks } | ForEach-Object { $_.command })
if ($d.model -eq 'opus' -and
    $d.hooks.PreToolUse[0].hooks[0].command -eq 'echo other-hook' -and
    ($ssCmds -contains 'echo existing-sessionstart') -and
    @($ssCmds | Where-Object { $_ -like '*memory-loader.sh*' }).Count -eq 1 -and
    @($d.hooks.SessionStart).Count -eq 2) {
    Ok "loader: unrelated keys and hooks preserved, ours appended"
} else { No "loader: settings merge damaged unrelated content" }

Write-Host "== loader: uninstall is surgical + sticky; -InstallLoader re-enables =="
Set-Content -Path (Join-Path $script:TH '.claude\hooks\memory-loader.conf') -Value 'skip_agent_types="Explore"'
$out = Run -UninstallLoader
Has    "loader: uninstall removes registration" $out "removed   memory-loader registration"
NoFile "loader: script removed" (Join-Path $script:TH '.claude\hooks\memory-loader.sh')
NoFile "loader: stamp removed"  (Join-Path $script:TH '.claude\hooks\.memory-loader.delivered')
FileIs "loader: conf left in place by uninstall" (Join-Path $script:TH '.claude\hooks\memory-loader.conf')
FileIs "loader: optout sentinel written" (Join-Path $script:TH '.claude\hooks\.memory-loader.optout')
$d = Get-Content (Join-Path $script:TH '.claude\settings.json') -Raw | ConvertFrom-Json
if ($d.hooks.PreToolUse[0].hooks[0].command -eq 'echo other-hook' -and
    @($d.hooks.SessionStart).Count -eq 1 -and
    $d.hooks.SessionStart[0].hooks[0].command -eq 'echo existing-sessionstart' -and
    -not $d.hooks.PSObject.Properties['SubagentStart']) {
    Ok "loader: other hooks survive uninstall, empty event key dropped"
} else { No "loader: uninstall damaged unrelated content" }
Hasnt "loader: ledger row gone" (Get-Content (Join-Path $script:TH '.claude\hooks\REGISTRY.md') -Raw) "| memory-loader |"
$out = Run
Has    "loader: bare re-run stays opted out" $out "opted out; -InstallLoader to re-enable"
NoFile "loader: not reinstalled while opted out" (Join-Path $script:TH '.claude\hooks\memory-loader.sh')
$out = Run -InstallLoader
Has    "loader: -InstallLoader reinstalls" $out "memory-loader hook installed"
NoFile "loader: optout cleared" (Join-Path $script:TH '.claude\hooks\.memory-loader.optout')

Write-Host "== loader: -NoLoader skips entirely =="
Fresh-Home
$out = Run -NoLoader
Has    "loader: skip reported" $out "skip      memory-loader hook (-NoLoader)"
NoFile "loader: no script" (Join-Path $script:TH '.claude\hooks\memory-loader.sh')
NoFile "loader: no settings.json" (Join-Path $script:TH '.claude\settings.json')

Write-Host "== loader: unmodified-stale auto-updates; edited copy needs -Force =="
Fresh-Home; Run | Out-Null
Set-Content -Path (Join-Path $script:TH '.claude\hooks\memory-loader.sh') -Value "old loader version`n" -NoNewline
Set-Content -Path (Join-Path $script:TH '.claude\hooks\.memory-loader.delivered') -Value (NHash (Join-Path $script:TH '.claude\hooks\memory-loader.sh')) -NoNewline
$out = Run
Has "loader: pristine-stale auto-updated on bare run" $out "updated to current version"
if ((NHash (Join-Path $script:TH '.claude\hooks\memory-loader.sh')) -eq (NHash (Join-Path $repoRoot 'hooks\memory-loader.sh'))) { Ok "loader: updated copy matches source" } else { No "loader: updated copy != source" }
Add-Content -Path (Join-Path $script:TH '.claude\hooks\memory-loader.sh') -Value "HAND EDIT"
$out = Run
Has "loader: edited copy -> DRIFT" $out "differs and looks edited"
$out = Run -Force
Has "loader: -Force overwrote edited copy" $out "overwrote modified copy"

Write-Host "== loader: registration drift -> report, -Force resync =="
Fresh-Home; Run | Out-Null
$sj = Join-Path $script:TH '.claude\settings.json'
(Get-Content $sj -Raw) -replace '"timeout": 10', '"timeout": 99' | Set-Content -Path $sj -NoNewline
$out = Run
Has "loader: registration drift reported" $out "memory-loader registration differs from canonical"
$out = Run -Force
Has "loader: -Force replaced registration" $out "memory-loader registration replaced"
$d = Get-Content $sj -Raw | ConvertFrom-Json
$allTen = $true
foreach ($ev in @('SessionStart', 'SubagentStart')) {
    foreach ($e in @($d.hooks.$ev)) {
        foreach ($h in @($e.hooks)) { if ($h.timeout -ne 10) { $allTen = $false } }
    }
}
if ($allTen) { Ok "loader: registration canonical again" } else { No "loader: registration not canonical after -Force" }

Write-Host "== loader: warning constants stay in lockstep with the docs =="
# The bounds live in the hook script; every doc that states them must move
# when they move. If a check here fails after you changed a constant, update
# the listed files AND these needles.
$hookSrc = Get-Content (Join-Path $repoRoot 'hooks\memory-loader.sh') -Raw
if ($hookSrc -match "(?m)^max_entry_bytes=9000$") { Ok "constants: hook byte bound is 9000" } else { No "constants: hook byte bound changed -- update docs + these checks" }
if ($hookSrc -match "(?m)^max_entry_lines=200$") { Ok "constants: hook line bound is 200" } else { No "constants: hook line bound changed -- update docs + these checks" }
if ($hookSrc -match '(?m)^skip_agent_types="Explore Plan"$') { Ok "constants: hook default skip list is Explore Plan" } else { No "constants: hook default skip list changed -- update BOOTSTRAP.md/HOOKS.md + this needle" }
foreach ($doc in @('hooks\memory-loader.sh', 'BOOTSTRAP.md', 'MEMORY.md.template', 'skills\memory-sweep\SKILL.md', 'skills\closeout\SKILL.md')) {
    if ((Get-Content (Join-Path $repoRoot $doc) -Raw).Contains('<!-- fold -->')) { Ok "constants: $doc states the fold marker" } else { No "constants: $doc missing the '<!-- fold -->' marker literal" }
}
foreach ($doc in @('BOOTSTRAP.md', 'README.md', 'MEMORY.md.template', 'CLAUDE.md', 'skills\memory-sweep\SKILL.md', 'skills\closeout\SKILL.md')) {
    if ((Get-Content (Join-Path $repoRoot $doc) -Raw) -match '~9(KB|,000)') { Ok "constants: $doc states the ~9KB bound" } else { No "constants: $doc missing the ~9KB bound" }
}

Write-Host "== loader: unparseable settings.json never touched =="
Fresh-Home
New-Item -ItemType Directory -Path (Join-Path $script:TH '.claude') -Force | Out-Null
Set-Content -Path (Join-Path $script:TH '.claude\settings.json') -Value '{ this is not json' -NoNewline
$out = Run
Has "loader: invalid settings -> WARN" $out "not valid JSON; not touching it"
if ((Get-Content (Join-Path $script:TH '.claude\settings.json') -Raw) -eq '{ this is not json') { Ok "loader: invalid settings left byte-identical" } else { No "loader: invalid settings was modified" }

# ---- per-skill matrix --------------------------------------------------------
# Factored into a function so every bundled skill gets identical coverage and the
# bash/ps1 lockstep stays manageable. Mirrors verify_skill in verify.sh -- keep
# the two in sync. Skill paths come from SkillDir/etc, which read the CURRENT
# $script:TH on every call (Fresh-Home reassigns it).
function Test-Skill($name) {
    $src = SkillSrc $name

    Write-Host "== ${name}: install / in-sync / edited-drift / -Force =="
    Fresh-Home
    Run | Out-Null
    $out = Run -InstallSkills -Skills $name
    Has    "${name}: install reported" $out "created   $(SkillTarget $name) ($name installed)"
    FileIs "${name}: SKILL.md present"         (SkillTarget $name)
    FileIs "${name}: .delivered stamp present" (SkillStamp $name)
    $out = Run
    Has    "${name}: bare run in sync" $out "(in sync)"
    Add-Content -Path (SkillTarget $name) -Value "HAND EDIT"
    $out = Run
    Has    "${name}: edited copy -> edited-drift report" $out "differs and looks edited"
    $out = Run -Force
    Has    "${name}: -Force overwrote modified" $out "overwrote modified copy"

    Write-Host "== ${name}: pristine-stale -> report, then re-install updates =="
    Set-Content -Path (SkillTarget $name) -Value "old version`n" -NoNewline
    Set-Content -Path (SkillStamp $name) -Value (NHash (SkillTarget $name)) -NoNewline
    $out = Run
    Has    "${name}: unmodified-stale -> 'newer version' report" $out "newer version available; your copy is unmodified"
    $out = Run -InstallSkills -Skills $name
    Has    "${name}: re-install updates pristine-stale copy" $out "updated to current version"
    if ((NHash (SkillTarget $name)) -eq (NHash $src)) { Ok "${name}: updated copy matches repo source" } else { No "${name}: updated copy != source" }

    Write-Host "== ${name}: uninstall preserves user files, removes only managed =="
    Set-Content -Path (Join-Path (SkillDir $name) 'user-notes.txt') -Value 'mine'
    $out = Run -UninstallSkills -Skills $name
    Has    "${name}: uninstall reported" $out "$name uninstalled"
    NoFile "${name}: SKILL.md removed"   (SkillTarget $name)
    NoFile "${name}: .delivered removed" (SkillStamp $name)
    FileIs "${name}: user file preserved" (Join-Path (SkillDir $name) 'user-notes.txt')
    FileIs "${name}: non-empty dir kept"  (SkillDir $name)
    Remove-Item (Join-Path (SkillDir $name) 'user-notes.txt') -Force
    Run -InstallSkills -Skills $name | Out-Null
    Run -UninstallSkills -Skills $name | Out-Null
    NoFile "${name}: empty dir removed on uninstall" (SkillDir $name)

    Write-Host "== ${name}: symlink/junction refusal (real junction) =="
    Fresh-Home; Run | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $script:TH '.claude\skills') -Force | Out-Null
    $ext = Join-Path $script:TH "ext-target-$name"; New-Item -ItemType Directory -Path $ext -Force | Out-Null
    New-Item -ItemType Junction -Path (SkillDir $name) -Target $ext | Out-Null
    $out = Run -InstallSkills -Skills $name
    Has    "${name}: refuses to write through a junction" $out "is a symlink/junction; not managing it"
    (Get-Item -LiteralPath (SkillDir $name) -Force).Delete()

    Write-Host "== ${name}: bare-run regression: never-installed USERPROFILE is stable =="
    Fresh-Home
    $o1 = Run; $o2 = Run
    Hasnt "${name}: never-installed run writes no $name" $o1 "($name installed)"
    Hasnt "${name}: repeat run still no DRIFT" $o2 "DRIFT"
}

Test-Skill closeout
Test-Skill memory-sweep

if ($script:TH -and (Test-Path $script:TH)) { Remove-Item -LiteralPath $script:TH -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ""
Write-Host "verify.ps1: $($script:pass) passed, $($script:fail) failed"
if ($script:fail -ne 0) { exit 1 }
