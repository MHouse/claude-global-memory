#!/usr/bin/env bash
# Manual verification harness for bootstrap.sh.
#
# Runs the BOOTSTRAP.md recipe against a throwaway HOME and asserts: the
# managed-surface idempotency + drift-detection + --force resync contract, and
# the full opt-in per-skill matrix (closeout + memory-sweep). This is the repo's manual test convention
# (no CI, no app) made runnable. Run it by hand before landing a bootstrap
# change:  bash test/verify.sh
#
# LOCKSTEP: keep in sync with test/verify.ps1 -- the two must assert the same
# cases. bootstrap.sh and bootstrap.ps1 must behave identically, so their
# verifiers must too.

set -uo pipefail   # deliberately NOT -e: run every assertion, tally at the end

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
boot="$repo_root/bootstrap.sh"
[ -f "$boot" ] || { echo "bootstrap.sh not found at $boot" >&2; exit 2; }

pass=0; fail=0
TH=""
cleanup() { [ -n "$TH" ] && rm -rf "$TH" 2>/dev/null; TH=""; }
trap cleanup EXIT
fresh_home() { cleanup; TH="$(mktemp -d)"; }
run() { HOME="$TH" bash "$boot" "$@" 2>&1; }

ok()  { pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
no()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
has() { if printf '%s' "$2" | grep -qF "$3"; then ok "$1"; else no "$1 -- expected to find: $3"; fi; }
hasnt(){ if printf '%s' "$2" | grep -qF "$3"; then no "$1 -- unexpected: $3"; else ok "$1"; fi; }
file(){ if [ -e "$2" ]; then ok "$1"; else no "$1 -- missing file: $2"; fi; }
nofile(){ if [ -e "$2" ]; then no "$1 -- file should be gone: $2"; else ok "$1"; fi; }

# Mirror bootstrap.sh's normalize + normalized_hash so we can forge a stamp.
_sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; }
normalize_t() { awk '{ sub(/\r$/,""); sub(/[ \t]+$/,""); print }' "$1" \
  | awk 'BEGIN{n=0}{a[n++]=$0}END{while(n>0&&a[n-1]=="")n--;for(i=0;i<n;i++)print a[i]}'; }
nhash() { printf '%s' "$(normalize_t "$1")" | _sha256 | awk '{print $1}'; }

echo "== managed surfaces: fresh install + idempotency =="
fresh_home
out="$(run)"
file   "fresh: memory dir created"     "$TH/.claude/memory"
file   "fresh: MEMORY.md created"      "$TH/.claude/memory/MEMORY.md"
file   "fresh: CLAUDE.md created"      "$TH/.claude/CLAUDE.md"
file   "fresh: REGISTRY.md created"    "$TH/.claude/hooks/REGISTRY.md"
has    "fresh: closeout skipped (opt-in)" "$out" "skip      closeout skill (not installed"
has    "fresh: memory-sweep skipped (opt-in)" "$out" "skip      memory-sweep skill (not installed"
out="$(run)"
hasnt  "idempotent: 2nd run reports no DRIFT" "$out" "DRIFT"
hasnt  "idempotent: 2nd run creates nothing"  "$out" "created"

echo "== managed surfaces: drift detect + --force resync + entry preservation =="
# add a user entry below ## Entries -- must survive --force
printf '\n- [my entry](x.md)\n' >> "$TH/.claude/memory/MEMORY.md"
# tamper the PREAMBLE (above ## Entries) by prepending a line
{ printf 'TAMPER preamble line\n'; cat "$TH/.claude/memory/MEMORY.md"; } > "$TH/.claude/memory/MEMORY.md.tmp" \
  && mv "$TH/.claude/memory/MEMORY.md.tmp" "$TH/.claude/memory/MEMORY.md"
out="$(run)"
has    "drift: MEMORY.md preamble drift reported" "$out" "DRIFT     $TH/.claude/memory/MEMORY.md"
out="$(run --force)"
has    "force: MEMORY.md synced" "$out" "synced    $TH/.claude/memory/MEMORY.md"
if grep -qF "[my entry](x.md)" "$TH/.claude/memory/MEMORY.md"; then ok "force: user entry below ## Entries preserved"; else no "force: user entry was clobbered"; fi

# ---- per-skill matrix --------------------------------------------------------
# Factored into a function so every bundled skill gets identical coverage and
# the bash/ps1 lockstep stays manageable. $1 = skill name. Mirrors Test-Skill in
# verify.ps1 -- keep the two in sync.
verify_skill() {
  local name=$1
  local ssrc="$repo_root/skills/$name/SKILL.md"
  local sdir starget sstamp
  # fresh_home reassigns $TH, so (re)derive the paths from the CURRENT $TH after
  # every fresh_home call -- never capture them once at function entry.
  _paths() { sdir="$TH/.claude/skills/$name"; starget="$sdir/SKILL.md"; sstamp="$sdir/.delivered"; }

  echo "== $name: install / in-sync / edited-drift / force =="
  fresh_home; _paths
  run >/dev/null
  out="$(run --install-skills "$name")"
  has    "$name: install reported" "$out" "created   $starget ($name installed)"
  file   "$name: SKILL.md present"  "$starget"
  file   "$name: .delivered stamp present" "$sstamp"
  out="$(run)"
  has    "$name: bare run in sync" "$out" "(in sync)"
  printf 'HAND EDIT\n' >> "$starget"
  out="$(run)"
  has    "$name: edited copy -> edited-drift report" "$out" "differs and looks edited"
  out="$(run --force)"
  has    "$name: --force overwrote modified" "$out" "overwrote modified copy"

  echo "== $name: pristine-stale -> report, then re-install updates =="
  printf 'old version\n' > "$starget"
  nhash "$starget" > "$sstamp"
  out="$(run)"
  has    "$name: unmodified-stale -> 'newer version' report" "$out" "newer version available; your copy is unmodified"
  out="$(run --install-skills "$name")"
  has    "$name: re-install updates pristine-stale copy" "$out" "updated to current version"
  if diff -q <(normalize_t "$ssrc") <(normalize_t "$starget") >/dev/null; then ok "$name: updated copy matches repo source"; else no "$name: updated copy != source"; fi

  echo "== $name: uninstall preserves user files, removes only managed =="
  printf 'mine\n' > "$sdir/user-notes.txt"
  out="$(run --uninstall-skills "$name")"
  has    "$name: uninstall reported" "$out" "$name uninstalled"
  nofile "$name: SKILL.md removed"   "$starget"
  nofile "$name: .delivered removed" "$sstamp"
  file   "$name: user file preserved" "$sdir/user-notes.txt"
  file   "$name: non-empty dir kept"  "$sdir"
  rm -f "$sdir/user-notes.txt"
  run --install-skills "$name" >/dev/null
  run --uninstall-skills "$name" >/dev/null
  nofile "$name: empty dir removed on uninstall" "$sdir"

  echo "== $name: symlink/junction refusal =="
  fresh_home; _paths; run >/dev/null
  mkdir -p "$TH/.claude/skills"
  if ln -s /tmp "$sdir" 2>/dev/null; then
    out="$(run --install-skills "$name")"
    has  "$name: refuses to write through a symlink" "$out" "is a symlink/junction; not managing it"
    rm -f "$sdir"
  else
    printf '  SKIP  %s: symlink refusal (this filesystem disallows symlinks; covered by verify.ps1 junction test)\n' "$name"
  fi

  echo "== $name: bare-run regression: never-installed HOME is stable =="
  fresh_home; _paths
  out1="$(run)"; out2="$(run)"
  hasnt "$name: never-installed run writes no $name" "$out1" "created   $sdir"
  hasnt "$name: repeat run still no DRIFT" "$out2" "DRIFT"
}

verify_skill closeout
verify_skill memory-sweep

echo ""
echo "verify.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
