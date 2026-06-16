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
$src  = Join-Path $repoRoot 'skills\closeout\SKILL.md'
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
function Cdir { Join-Path $script:TH '.claude\skills\closeout' }

Write-Host "== managed surfaces: fresh install + idempotency =="
Fresh-Home
$out = Run
FileIs "fresh: memory dir created"   (Join-Path $script:TH '.claude\memory')
FileIs "fresh: MEMORY.md created"    (Join-Path $script:TH '.claude\memory\MEMORY.md')
FileIs "fresh: CLAUDE.md created"    (Join-Path $script:TH '.claude\CLAUDE.md')
FileIs "fresh: REGISTRY.md created"  (Join-Path $script:TH '.claude\hooks\REGISTRY.md')
Has    "fresh: closeout skipped (opt-in)" $out "skip      closeout skill (not installed"
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

Write-Host "== closeout: install / in-sync / edited-drift / -Force =="
Fresh-Home
Run | Out-Null
$out = Run -InstallCloseout
Has    "closeout: install reported" $out "(closeout installed)"
FileIs "closeout: SKILL.md present"         (Join-Path (Cdir) 'SKILL.md')
FileIs "closeout: .delivered stamp present" (Join-Path (Cdir) '.delivered')
$out = Run
Has    "closeout: bare run in sync" $out "(in sync)"
Add-Content -Path (Join-Path (Cdir) 'SKILL.md') -Value "HAND EDIT"
$out = Run
Has    "closeout: edited copy -> edited-drift report" $out "differs and looks edited"
$out = Run -Force
Has    "closeout: -Force overwrote modified" $out "overwrote modified copy"

Write-Host "== closeout: pristine-stale -> report, then re-install updates =="
Set-Content -Path (Join-Path (Cdir) 'SKILL.md') -Value "old version`n" -NoNewline
Set-Content -Path (Join-Path (Cdir) '.delivered') -Value (NHash (Join-Path (Cdir) 'SKILL.md')) -NoNewline
$out = Run
Has    "closeout: unmodified-stale -> 'newer version' report" $out "newer version available; your copy is unmodified"
$out = Run -InstallCloseout
Has    "closeout: re-install updates pristine-stale copy" $out "updated to current version"
if ((NHash (Join-Path (Cdir) 'SKILL.md')) -eq (NHash $src)) { Ok "closeout: updated copy matches repo source" } else { No "closeout: updated copy != source" }

Write-Host "== closeout: uninstall preserves user files, removes only managed =="
Set-Content -Path (Join-Path (Cdir) 'user-notes.txt') -Value 'mine'
$out = Run -UninstallCloseout
Has    "closeout: uninstall reported" $out "closeout uninstalled"
NoFile "closeout: SKILL.md removed"   (Join-Path (Cdir) 'SKILL.md')
NoFile "closeout: .delivered removed" (Join-Path (Cdir) '.delivered')
FileIs "closeout: user file preserved" (Join-Path (Cdir) 'user-notes.txt')
FileIs "closeout: non-empty dir kept"  (Cdir)
Remove-Item (Join-Path (Cdir) 'user-notes.txt') -Force
Run -InstallCloseout | Out-Null
Run -UninstallCloseout | Out-Null
NoFile "closeout: empty dir removed on uninstall" (Cdir)

Write-Host "== closeout: symlink/junction refusal (real junction) =="
Fresh-Home; Run | Out-Null
New-Item -ItemType Directory -Path (Join-Path $script:TH '.claude\skills') -Force | Out-Null
$ext = Join-Path $script:TH 'ext-target'; New-Item -ItemType Directory -Path $ext -Force | Out-Null
New-Item -ItemType Junction -Path (Cdir) -Target $ext | Out-Null
$out = Run -InstallCloseout
Has    "closeout: refuses to write through a junction" $out "is a symlink/junction; not managing it"
(Get-Item -LiteralPath (Cdir) -Force).Delete()

Write-Host "== bare-run regression: never-installed USERPROFILE is stable =="
Fresh-Home
$o1 = Run; $o2 = Run
Hasnt "bare: never-installed run writes no closeout" $o1 "(closeout installed)"
Hasnt "bare: repeat run still no DRIFT" $o2 "DRIFT"

if ($script:TH -and (Test-Path $script:TH)) { Remove-Item -LiteralPath $script:TH -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ""
Write-Host "verify.ps1: $($script:pass) passed, $($script:fail) failed"
if ($script:fail -ne 0) { exit 1 }
