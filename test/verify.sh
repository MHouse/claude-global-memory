#!/usr/bin/env bash
# Manual verification harness for bootstrap.sh.
#
# Runs the BOOTSTRAP.md recipe against a throwaway HOME and asserts: the
# managed-surface idempotency + drift-detection + --force resync contract, the
# memory-loader contract (default-on install, surgical settings.json merge,
# agent-type filter, sticky uninstall), and the full opt-in per-skill matrix
# (closeout + memory-sweep). This is the repo's manual test convention
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

# ---- memory-loader (default-on) ----------------------------------------------
# Mirrors the loader block in verify.ps1 -- keep the two in sync. JSON asserts
# pipe the file through python ON STDIN so a Windows-native python under local
# Git Bash (which can't open /tmp msys paths) behaves the same as Linux CI.
py=""
for _c in python3 python; do
  if command -v "$_c" >/dev/null 2>&1 && "$_c" -c 'import json' >/dev/null 2>&1; then py="$_c"; break; fi
done
json_ok() { # $1 = label, $2 = json file, $3 = python statements over parsed d
  if [ -z "$py" ]; then printf '  SKIP  %s (no python for JSON asserts)\n' "$1"; return 0; fi
  if "$py" -c "import json,sys; d=json.load(sys.stdin); $3" < "$2" >/dev/null 2>&1; then ok "$1"; else no "$1"; fi
}

echo "== loader: fresh install (default-on) =="
fresh_home
out="$(run)"
file   "loader: script installed"       "$TH/.claude/hooks/memory-loader.sh"
file   "loader: stamp present"          "$TH/.claude/hooks/.memory-loader.delivered"
file   "loader: settings.json created"  "$TH/.claude/settings.json"
has    "loader: registration reported"  "$out" "memory-loader registered under SessionStart + SubagentStart"
has    "loader: ledger row appended"    "$out" "appended  memory-loader row"
json_ok "loader: valid JSON, both events, one entry each" "$TH/.claude/settings.json" \
  "assert len(d['hooks']['SessionStart'])==1 and len(d['hooks']['SubagentStart'])==1"

echo "== loader: idempotent re-run =="
out="$(run)"
hasnt  "loader: 2nd run no DRIFT"           "$out" "DRIFT"
hasnt  "loader: 2nd run creates nothing"    "$out" "created"
if [ "$(grep -c 'memory-loader.sh' "$TH/.claude/settings.json")" -eq 2 ]; then ok "loader: no duplicate registrations"; else no "loader: duplicate registrations in settings.json"; fi
if [ "$(grep -c '^| memory-loader |' "$TH/.claude/hooks/REGISTRY.md")" -eq 1 ]; then ok "loader: single ledger row"; else no "loader: duplicate ledger rows"; fi

echo "== loader: agent-type filter + payload shape =="
hook="$TH/.claude/hooks/memory-loader.sh"
printf -- '- [loader test entry](tools/x.md) -- with "quotes" and a \\ backslash\n' >> "$TH/.claude/memory/MEMORY.md"
o="$(printf '%s' '{"agent_type":"Explore","hook_event_name":"SubagentStart"}' | HOME="$TH" bash "$hook")"
if [ -z "$o" ]; then ok "loader: Explore skipped"; else no "loader: Explore not skipped"; fi
o="$(printf '%s' '{"agent_type":"Plan","hook_event_name":"SubagentStart"}' | HOME="$TH" bash "$hook")"
if [ -z "$o" ]; then ok "loader: Plan skipped"; else no "loader: Plan not skipped"; fi
o="$(printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Bash"}' | HOME="$TH" bash "$hook")"
if [ -z "$o" ]; then ok "loader: other events silent"; else no "loader: other events not silent"; fi
o="$(printf '%s' '{"agent_type":"general-purpose","hook_event_name":"SubagentStart"}' | HOME="$TH" bash "$hook")"
if [ -z "$py" ]; then
  printf '  SKIP  loader: subagent payload JSON assert (no python)\n'
elif printf '%s' "$o" | "$py" -c "import json,sys; d=json.load(sys.stdin); h=d['hookSpecificOutput']; assert h['hookEventName']=='SubagentStart'; assert 'loader test entry' in h['additionalContext']" >/dev/null 2>&1; then
  ok "loader: general-purpose gets valid JSON (quotes/backslash escaped)"
else
  no "loader: general-purpose payload invalid JSON or missing entry"
fi
o="$(printf '%s' '{"hook_event_name":"SessionStart","source":"startup"}' | HOME="$TH" bash "$hook")"
case "$o" in *"Cross-project memory index"*) ok "loader: SessionStart payload present";; *) no "loader: SessionStart payload missing";; esac

echo "== loader: empty index injects nothing; oversized index warns =="
fresh_home
run >/dev/null
o="$(printf '%s' '{"hook_event_name":"SessionStart","source":"startup"}' | HOME="$TH" bash "$TH/.claude/hooks/memory-loader.sh")"
if [ -z "$o" ]; then ok "loader: empty Entries -> silent"; else no "loader: empty Entries injected something"; fi
for _i in $(seq 1 205); do printf -- '- [e%d](x.md) -- filler\n' "$_i" >> "$TH/.claude/memory/MEMORY.md"; done
o="$(printf '%s' '{"hook_event_name":"SessionStart"}' | HOME="$TH" bash "$TH/.claude/hooks/memory-loader.sh" 2>/dev/null)"
case "$o" in *"WARNING:"*) ok "loader: size warning past 200 entry lines";; *) no "loader: size warning missing";; esac

echo "== loader: preserves unrelated settings.json content =="
fresh_home
mkdir -p "$TH/.claude"
cat > "$TH/.claude/settings.json" <<'EOF'
{
  "model": "opus",
  "hooks": {
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo other-hook"}]}],
    "SessionStart": [{"hooks": [{"type": "command", "command": "echo existing-sessionstart"}]}]
  }
}
EOF
out="$(run)"
has    "loader: appended into existing settings" "$out" "appended  memory-loader registration"
json_ok "loader: unrelated keys and hooks preserved, ours appended" "$TH/.claude/settings.json" \
  "assert d['model']=='opus'; assert d['hooks']['PreToolUse'][0]['hooks'][0]['command']=='echo other-hook'; cmds=[h['command'] for e in d['hooks']['SessionStart'] for h in e['hooks']]; assert 'echo existing-sessionstart' in cmds; assert any('memory-loader.sh' in c for c in cmds); assert len(d['hooks']['SessionStart'])==2"

echo "== loader: uninstall is surgical + sticky; --install-loader re-enables =="
out="$(run --uninstall-loader)"
has    "loader: uninstall removes registration" "$out" "removed   memory-loader registration"
nofile "loader: script removed" "$TH/.claude/hooks/memory-loader.sh"
nofile "loader: stamp removed"  "$TH/.claude/hooks/.memory-loader.delivered"
file   "loader: optout sentinel written" "$TH/.claude/hooks/.memory-loader.optout"
json_ok "loader: other hooks survive uninstall, empty event key dropped" "$TH/.claude/settings.json" \
  "assert d['hooks']['PreToolUse'][0]['hooks'][0]['command']=='echo other-hook'; assert [h['command'] for e in d['hooks']['SessionStart'] for h in e['hooks']]==['echo existing-sessionstart']; assert 'SubagentStart' not in d['hooks']"
hasnt  "loader: ledger row gone" "$(cat "$TH/.claude/hooks/REGISTRY.md")" "| memory-loader |"
out="$(run)"
has    "loader: bare re-run stays opted out" "$out" "opted out; --install-loader to re-enable"
nofile "loader: not reinstalled while opted out" "$TH/.claude/hooks/memory-loader.sh"
out="$(run --install-loader)"
has    "loader: --install-loader reinstalls" "$out" "memory-loader hook installed"
nofile "loader: optout cleared" "$TH/.claude/hooks/.memory-loader.optout"

echo "== loader: --no-loader skips entirely =="
fresh_home
out="$(run --no-loader)"
has    "loader: skip reported" "$out" "skip      memory-loader hook (--no-loader)"
nofile "loader: no script" "$TH/.claude/hooks/memory-loader.sh"
nofile "loader: no settings.json" "$TH/.claude/settings.json"

echo "== loader: unmodified-stale auto-updates; edited copy needs --force =="
fresh_home; run >/dev/null
printf 'old loader version\n' > "$TH/.claude/hooks/memory-loader.sh"
nhash "$TH/.claude/hooks/memory-loader.sh" > "$TH/.claude/hooks/.memory-loader.delivered"
out="$(run)"
has    "loader: pristine-stale auto-updated on bare run" "$out" "updated to current version"
if diff -q <(normalize_t "$repo_root/hooks/memory-loader.sh") <(normalize_t "$TH/.claude/hooks/memory-loader.sh") >/dev/null; then ok "loader: updated copy matches source"; else no "loader: updated copy != source"; fi
printf 'HAND EDIT\n' >> "$TH/.claude/hooks/memory-loader.sh"
out="$(run)"
has    "loader: edited copy -> DRIFT" "$out" "differs and looks edited"
out="$(run --force)"
has    "loader: --force overwrote edited copy" "$out" "overwrote modified copy"

echo "== loader: registration drift -> report, --force resync =="
fresh_home; run >/dev/null
sed -i.bak 's/"timeout": 10/"timeout": 99/' "$TH/.claude/settings.json" && rm -f "$TH/.claude/settings.json.bak"
out="$(run)"
has    "loader: registration drift reported" "$out" "memory-loader registration differs from canonical"
out="$(run --force)"
has    "loader: --force replaced registration" "$out" "memory-loader registration replaced"
json_ok "loader: registration canonical again" "$TH/.claude/settings.json" \
  "assert all(e['hooks'][0]['timeout']==10 for ev in ('SessionStart','SubagentStart') for e in d['hooks'][ev])"

echo "== loader: unparseable settings.json never touched =="
fresh_home
mkdir -p "$TH/.claude"
printf '{ this is not json' > "$TH/.claude/settings.json"
out="$(run)"
has    "loader: invalid settings -> WARN" "$out" "not valid JSON; not touching it"
if [ "$(cat "$TH/.claude/settings.json")" = "{ this is not json" ]; then ok "loader: invalid settings left byte-identical"; else no "loader: invalid settings was modified"; fi

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
