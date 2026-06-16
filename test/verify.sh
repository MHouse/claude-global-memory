#!/usr/bin/env bash
# Manual verification harness for bootstrap.sh.
#
# Runs the BOOTSTRAP.md recipe against a throwaway HOME and asserts: the
# managed-surface idempotency + drift-detection + --force resync contract, and
# the full opt-in closeout matrix. This is the repo's manual test convention
# (no CI, no app) made runnable. Run it by hand before landing a bootstrap
# change:  bash test/verify.sh
#
# LOCKSTEP: keep in sync with test/verify.ps1 -- the two must assert the same
# cases. bootstrap.sh and bootstrap.ps1 must behave identically, so their
# verifiers must too.

set -uo pipefail   # deliberately NOT -e: run every assertion, tally at the end

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
boot="$repo_root/bootstrap.sh"
src="$repo_root/skills/closeout/SKILL.md"
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

echo "== closeout: install / in-sync / edited-drift / force =="
fresh_home
run >/dev/null
out="$(run --install-closeout)"
has    "closeout: install reported" "$out" "created   $TH/.claude/skills/closeout/SKILL.md (closeout installed)"
file   "closeout: SKILL.md present"  "$TH/.claude/skills/closeout/SKILL.md"
file   "closeout: .delivered stamp present" "$TH/.claude/skills/closeout/.delivered"
out="$(run)"
has    "closeout: bare run in sync" "$out" "(in sync)"
printf 'HAND EDIT\n' >> "$TH/.claude/skills/closeout/SKILL.md"
out="$(run)"
has    "closeout: edited copy -> edited-drift report" "$out" "differs and looks edited"
out="$(run --force)"
has    "closeout: --force overwrote modified" "$out" "overwrote modified copy"

echo "== closeout: pristine-stale -> report, then re-install updates =="
printf 'old version\n' > "$TH/.claude/skills/closeout/SKILL.md"
nhash "$TH/.claude/skills/closeout/SKILL.md" > "$TH/.claude/skills/closeout/.delivered"
out="$(run)"
has    "closeout: unmodified-stale -> 'newer version' report" "$out" "newer version available; your copy is unmodified"
out="$(run --install-closeout)"
has    "closeout: re-install updates pristine-stale copy" "$out" "updated to current version"
if diff -q <(normalize_t "$src") <(normalize_t "$TH/.claude/skills/closeout/SKILL.md") >/dev/null; then ok "closeout: updated copy matches repo source"; else no "closeout: updated copy != source"; fi

echo "== closeout: uninstall preserves user files, removes only managed =="
printf 'mine\n' > "$TH/.claude/skills/closeout/user-notes.txt"
out="$(run --uninstall-closeout)"
has    "closeout: uninstall reported" "$out" "closeout uninstalled"
nofile "closeout: SKILL.md removed"   "$TH/.claude/skills/closeout/SKILL.md"
nofile "closeout: .delivered removed" "$TH/.claude/skills/closeout/.delivered"
file   "closeout: user file preserved" "$TH/.claude/skills/closeout/user-notes.txt"
file   "closeout: non-empty dir kept"  "$TH/.claude/skills/closeout"
rm -f "$TH/.claude/skills/closeout/user-notes.txt"
run --install-closeout >/dev/null
run --uninstall-closeout >/dev/null
nofile "closeout: empty dir removed on uninstall" "$TH/.claude/skills/closeout"

echo "== closeout: symlink/junction refusal =="
fresh_home; run >/dev/null
mkdir -p "$TH/.claude/skills"
if ln -s /tmp "$TH/.claude/skills/closeout" 2>/dev/null; then
  out="$(run --install-closeout)"
  has  "closeout: refuses to write through a symlink" "$out" "is a symlink/junction; not managing it"
  rm -f "$TH/.claude/skills/closeout"
else
  printf '  SKIP  closeout: symlink refusal (this filesystem disallows symlinks; covered by verify.ps1 junction test)\n'
fi

echo "== bare-run regression: never-installed HOME is stable =="
fresh_home
out1="$(run)"; out2="$(run)"
hasnt "bare: never-installed run writes no closeout" "$out1" "created   $TH/.claude/skills/closeout"
hasnt "bare: repeat run still no DRIFT" "$out2" "DRIFT"

echo ""
echo "verify.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
