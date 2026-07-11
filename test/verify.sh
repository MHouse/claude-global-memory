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
if [ -n "$py" ]; then
  if printf '%s' "$o" | "$py" -c "import json,sys; c=json.load(sys.stdin)['hookSpecificOutput']['additionalContext']; assert c.splitlines()[-1].startswith('INDEX-END (')" >/dev/null 2>&1; then
    ok "loader: payload ends with the INDEX-END sentinel"
  else
    no "loader: INDEX-END sentinel missing from payload tail"
  fi
fi
o="$(printf '%s' '{"hook_event_name":"SessionStart","source":"startup"}' | HOME="$TH" bash "$hook")"
case "$o" in *"Cross-project memory index"*) ok "loader: SessionStart payload present";; *) no "loader: SessionStart payload missing";; esac

echo "== loader: conf overrides the skip list; broken conf never kills injection =="
conffile="$TH/.claude/hooks/memory-loader.conf"
printf 'skip_agent_types="Explore CustomLean"\r\n' > "$conffile"   # CRLF on purpose: Windows editors write it
o="$(printf '%s' '{"agent_type":"CustomLean","hook_event_name":"SubagentStart"}' | HOME="$TH" bash "$hook")"
if [ -z "$o" ]; then ok "conf: added agent type skipped"; else no "conf: added agent type not skipped"; fi
o="$(printf '%s' '{"agent_type":"Plan","hook_event_name":"SubagentStart"}' | HOME="$TH" bash "$hook")"
if [ -n "$o" ]; then ok "conf: value replaces the default (Plan now injects)"; else no "conf: default skip list still active despite conf"; fi
o="$(printf '%s' '{"agent_type":"Explore","hook_event_name":"SubagentStart"}' | HOME="$TH" bash "$hook")"
if [ -z "$o" ]; then ok "conf: kept agent type still skipped"; else no "conf: kept agent type not skipped"; fi
printf 'this is ( not a conf\n' > "$conffile"
o="$(printf '%s' '{"agent_type":"general-purpose","hook_event_name":"SubagentStart"}' | HOME="$TH" bash "$hook")"
if [ -n "$o" ]; then ok "conf: garbage conf ignored, injection alive"; else no "conf: garbage conf killed injection"; fi
o="$(printf '%s' '{"agent_type":"Explore","hook_event_name":"SubagentStart"}' | HOME="$TH" bash "$hook")"
if [ -z "$o" ]; then ok "conf: garbage conf -> defaults still apply"; else no "conf: garbage conf broke the defaults"; fi
conf_before="$(cat "$conffile")"
out="$(run)"
hasnt "conf: bare re-run stays in sync with conf present" "$out" "DRIFT"
if [ "$(cat "$conffile")" = "$conf_before" ]; then ok "conf: bare run leaves conf untouched"; else no "conf: bare run modified conf"; fi
rm -f "$conffile"

echo "== loader: fold -- subagents get above-fold only; strict marker grammar =="
fresh_home
run >/dev/null
hook="$TH/.claude/hooks/memory-loader.sh"
mem="$TH/.claude/memory/MEMORY.md"
printf -- '- [above entry](a.md) -- ambient\n<!-- fold -->\n- [below entry](b.md) -- tail\n- [below two](c.md) -- tail2\n' >> "$mem"
o="$(printf '%s' '{"agent_type":"general-purpose","hook_event_name":"SubagentStart"}' | HOME="$TH" bash "$hook" 2>/dev/null)"
has   "fold: subagent gets above-fold" "$o" "above entry"
hasnt "fold: subagent does not get below-fold" "$o" "below entry"
has   "fold: segment sentinel carries the pointer" "$o" "lines below the fold -- read ~/.claude/memory/MEMORY.md"
if [ -n "$py" ]; then
  if printf '%s' "$o" | "$py" -c "import json,sys; c=json.load(sys.stdin)['hookSpecificOutput']['additionalContext']; assert c.splitlines()[-1].startswith('INDEX-END (')" >/dev/null 2>&1; then
    ok "fold: segment sentinel keeps the stable prefix (valid JSON)"
  else
    no "fold: segment sentinel broke the INDEX-END prefix contract"
  fi
fi
o="$(printf '%s' '{"hook_event_name":"SessionStart","source":"startup"}' | HOME="$TH" bash "$hook" 2>/dev/null)"
has   "fold: main session still gets the full index" "$o" "below two"
hasnt "fold: literal marker stripped from full payload" "$o" "fold -->"
hasnt "fold: main sentinel not segment-aware" "$o" "below the fold"
o="$(printf '%s' '{"agent_type":"Explore","hook_event_name":"SubagentStart"}' | HOME="$TH" bash "$hook" 2>/dev/null)"
if [ -z "$o" ]; then ok "fold: skip list still wins before fold work"; else no "fold: Explore not skipped with marker present"; fi
out="$(run)"
hasnt "fold: bare re-run reports no DRIFT with marker present" "$out" "DRIFT"
run --force >/dev/null
if [ "$(grep -c '^<!-- fold -->$' "$mem")" -eq 1 ] && grep -q 'below two' "$mem"; then ok "fold: marker + tail survive bare and --force runs"; else no "fold: bootstrap disturbed the marker or tail"; fi
printf '# H\n\n## Entries\n\n- [inline entry](y.md) -- mentions <!-- fold --> inline\n- [tail entry](t.md) -- t\n' > "$mem"
o="$(printf '%s' '{"agent_type":"general-purpose","hook_event_name":"SubagentStart"}' | HOME="$TH" bash "$hook" 2>/dev/null)"
has   "fold: embedded marker text is data (tail still injected)" "$o" "tail entry"
hasnt "fold: no phantom segment sentinel" "$o" "below the fold"
printf '# H\n\n## Entries\n\n- [a one](a.md) -- a\n   <!-- fold -->   \n- [m one](m.md) -- mid\n<!-- fold -->\n- [t one](t.md) -- tail\n' > "$mem"
o="$(printf '%s' '{"agent_type":"general-purpose","hook_event_name":"SubagentStart"}' | HOME="$TH" bash "$hook" 2>/dev/null)"
has   "fold: whitespace-padded marker honored" "$o" "a one"
hasnt "fold: first marker wins (mid withheld)" "$o" "m one"
has   "fold: withheld count spans to the tail" "$o" "3 lines below the fold"
printf '# H\n\n## Entries\n<!-- fold -->\n- [t only](t.md) -- t\n' > "$mem"
o="$(printf '%s' '{"agent_type":"general-purpose","hook_event_name":"SubagentStart"}' | HOME="$TH" bash "$hook" 2>/dev/null)"
has   "fold: empty above-fold still emits pointer sentinel" "$o" "INDEX-END (0 lines, 0 bytes;"
printf '# H\n\n## Entries\n\n- [only entry](o.md) -- o\n<!-- fold -->\n' > "$mem"
o="$(printf '%s' '{"agent_type":"general-purpose","hook_event_name":"SubagentStart"}' | HOME="$TH" bash "$hook" 2>/dev/null)"
has   "fold: empty tail withholds nothing" "$o" "only entry"
hasnt "fold: empty tail -> plain sentinel" "$o" "below the fold"
{ printf '# H\n\n## Entries\n\n'; fatf="$(printf 'y%.0s' $(seq 1 380))"; for _i in $(seq 1 25); do printf -- '- [af%d](x.md) -- %s\n' "$_i" "$fatf"; done; printf -- '<!-- fold -->\n- [tail z](z.md) -- z\n'; } > "$mem"
o="$(printf '%s' '{"agent_type":"general-purpose","hook_event_name":"SubagentStart"}' | HOME="$TH" bash "$hook" 2>/dev/null)"
has   "fold: oversized above-fold warns by segment name" "$o" "ABOVE-FOLD segment alone"
{ printf '# H\n\n## Entries\n\n- [head rule](h.md) -- imperative\n<!-- fold -->\n'; for _i in $(seq 1 25); do printf -- '- [tail%d](x.md) -- %s\n' "$_i" "$fatf"; done; } > "$mem"
o="$(printf '%s' '{"hook_event_name":"SessionStart","source":"startup"}' | HOME="$TH" bash "$hook" 2>/dev/null)"
has   "fold: over-budget main auto-degrades to above-fold" "$o" "head rule"
hasnt "fold: degraded main withholds the tail" "$o" "tail7"
has   "fold: degraded main sentinel carries the pointer" "$o" "lines below the fold"
hasnt "fold: degraded main under-budget segment gets no warning" "$o" "WARNING"

echo "== loader: empty index injects nothing; oversized index warns =="
fresh_home
run >/dev/null
o="$(printf '%s' '{"hook_event_name":"SessionStart","source":"startup"}' | HOME="$TH" bash "$TH/.claude/hooks/memory-loader.sh")"
if [ -z "$o" ]; then ok "loader: empty Entries -> silent"; else no "loader: empty Entries injected something"; fi
for _i in $(seq 1 205); do printf -- '- [e%d](x.md) -- filler\n' "$_i" >> "$TH/.claude/memory/MEMORY.md"; done
o="$(printf '%s' '{"hook_event_name":"SessionStart"}' | HOME="$TH" bash "$TH/.claude/hooks/memory-loader.sh" 2>/dev/null)"
case "$o" in *"lines (cap"*) ok "loader: line warning past 200 entry lines";; *) no "loader: line warning missing";; esac
case "$o" in *"preview"*) no "loader: byte warning fired on a small-byte index";; *) ok "loader: byte warning not misfired";; esac
# byte budget: few-but-fat lines past ~9KB -> truncation-preview warning wins
fresh_home
run >/dev/null
fat="$(printf 'x%.0s' $(seq 1 380))"
for _i in $(seq 1 25); do printf -- '- [fat%d](x.md) -- %s\n' "$_i" "$fat" >> "$TH/.claude/memory/MEMORY.md"; done
o="$(printf '%s' '{"hook_event_name":"SessionStart"}' | HOME="$TH" bash "$TH/.claude/hooks/memory-loader.sh" 2>/dev/null)"
case "$o" in *"preview"*) ok "loader: byte warning past ~9KB of entries";; *) no "loader: byte warning missing";; esac

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
printf 'skip_agent_types="Explore"\n' > "$TH/.claude/hooks/memory-loader.conf"
out="$(run --uninstall-loader)"
has    "loader: uninstall removes registration" "$out" "removed   memory-loader registration"
nofile "loader: script removed" "$TH/.claude/hooks/memory-loader.sh"
nofile "loader: stamp removed"  "$TH/.claude/hooks/.memory-loader.delivered"
file   "loader: conf left in place by uninstall" "$TH/.claude/hooks/memory-loader.conf"
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

echo "== loader: warning constants stay in lockstep with the docs =="
# The bounds live in the hook script; every doc that states them must move
# when they move. If a grep here fails after you changed a constant, update
# the listed files AND these needles.
if grep -q '^max_entry_bytes=9000$' "$repo_root/hooks/memory-loader.sh"; then ok "constants: hook byte bound is 9000"; else no "constants: hook byte bound changed -- update docs + these greps"; fi
if grep -q '^max_entry_lines=200$' "$repo_root/hooks/memory-loader.sh"; then ok "constants: hook line bound is 200"; else no "constants: hook line bound changed -- update docs + these greps"; fi
if grep -q '^skip_agent_types="Explore Plan"$' "$repo_root/hooks/memory-loader.sh"; then ok "constants: hook default skip list is Explore Plan"; else no "constants: hook default skip list changed -- update BOOTSTRAP.md/HOOKS.md + this grep"; fi
for _doc in hooks/memory-loader.sh BOOTSTRAP.md MEMORY.md.template skills/memory-sweep/SKILL.md skills/closeout/SKILL.md; do
  if grep -qF -- '<!-- fold -->' "$repo_root/$_doc"; then ok "constants: $_doc states the fold marker"; else no "constants: $_doc missing the '<!-- fold -->' marker literal"; fi
done
for _doc in BOOTSTRAP.md README.md MEMORY.md.template CLAUDE.md skills/memory-sweep/SKILL.md skills/closeout/SKILL.md; do
  if grep -Eq '~9(KB|,000)' "$repo_root/$_doc"; then ok "constants: $_doc states the ~9KB bound"; else no "constants: $_doc missing the ~9KB bound"; fi
done

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
