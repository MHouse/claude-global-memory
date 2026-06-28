<#
.SYNOPSIS
  Manual verification harness for bootstrap.ps1.

.DESCRIPTION
  Runs the BOOTSTRAP.md recipe against a throwaway USERPROFILE and asserts the
  managed-surface idempotency + drift-detection + -Force resync contract, and
  the full opt-in closeout matrix. The repo's manual test convention (no CI, no
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
Has    "fresh: consolidate-memory-deep skipped (opt-in)" $out "skip      consolidate-memory-deep skill (not installed"
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
Test-Skill consolidate-memory-deep

if ($script:TH -and (Test-Path $script:TH)) { Remove-Item -LiteralPath $script:TH -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ""
Write-Host "verify.ps1: $($script:pass) passed, $($script:fail) failed"
if ($script:fail -ne 0) { exit 1 }
