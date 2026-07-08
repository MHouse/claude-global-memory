#!/usr/bin/env bash
# memory-loader: SessionStart + SubagentStart hook for the cross-project
# memory layer. Injects the '## Entries' section of ~/.claude/memory/MEMORY.md
# into context, giving the cross-project index the same mechanical load
# guarantee the harness gives per-project memory -- instead of a model-followed
# "read the index at session start" instruction (see HOOKS.md, "The
# load-bearing exception", and the 2026-07 postmortem behind it).
#
# One script, two registrations (made by the bootstrap):
#   SessionStart  -- main sessions: startup / resume / clear / compact.
#   SubagentStart -- spawned subagents, which inherit CLAUDE.md but NOT
#                    SessionStart output. Lean agent types below are skipped.
#
# Portable POSIX-ish bash + sed/awk only (no jq), per HOOKS.md. Managed by the
# claude-global-memory bootstrap as a whole-file surface (stamp:
# ~/.claude/hooks/.memory-loader.delivered); hand-edits are preserved until
# --force. Ledger row: ~/.claude/hooks/REGISTRY.md.

# Lean agent types to skip: they deliberately load no CLAUDE.md to stay
# token-lean, are read-only, and multiply injection cost under fan-out.
# Keep in sync with the filter documented in BOOTSTRAP.md.
skip_agent_types="Explore Plan"

# Warn when the injected index outgrows its budget. Two bounds:
#   - bytes: the harness truncates injected context past ~10k characters,
#     keeping only a ~2KB preview -- entries below the fold lose the
#     always-in-context guarantee (probe-measured 2026-07-08, CLI 2.1.204).
#     Warn with margin before that. This bound usually bites first.
#   - lines: the documented ~200-line routing-quality cap (README "Cost note").
max_entry_bytes=9000
max_entry_lines=200

input=$(cat)

# Match ONLY the identifying field, never the whole payload (HOOKS.md lesson).
field() {
    printf '%s' "$input" | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

event=$(field hook_event_name)
case "$event" in
    SessionStart|SubagentStart) ;;
    *) exit 0 ;;
esac

# SubagentStart carries agent_type; if a SessionStart payload ever carries one
# (SDK contexts), the same skip applies.
agent_type=$(field agent_type)
if [ -n "$agent_type" ]; then
    for t in $skip_agent_types; do
        [ "$agent_type" = "$t" ] && exit 0
    done
fi

# Git Bash launched outside a login shell may lack HOME; fall back to the
# Windows profile.
home_dir="${HOME:-${USERPROFILE:-}}"
[ -n "$home_dir" ] || exit 0
index="${home_dir}/.claude/memory/MEMORY.md"
[ -f "$index" ] || exit 0

# Everything below the '## Entries' marker. Empty index -> inject nothing
# (fresh installs cost zero tokens).
entries=$(awk '/^## Entries[[:space:]]*$/ { found=1; next } found { sub(/\r$/, ""); print }' "$index")
[ -n "$(printf '%s' "$entries" | tr -d '[:space:]')" ] || exit 0

payload="Cross-project memory index -- injected from ~/.claude/memory/MEMORY.md (see the Cross-project memory section of the global CLAUDE.md). One line per entry; read the linked entry file under ~/.claude/memory/ before acting on one.

$entries"

entry_lines=$(printf '%s\n' "$entries" | wc -l | tr -d '[:space:]')
entry_bytes=$(printf '%s' "$entries" | wc -c | tr -d '[:space:]')
warning=""
if [ "$entry_bytes" -gt "$max_entry_bytes" ]; then
    warning="WARNING: the cross-project index is ${entry_bytes} bytes; the harness keeps only a ~2KB preview of injections past ~10k characters, so entries below the fold lose the always-in-context guarantee -- trim or promote (see memory-sweep) and keep imperative lines at the top."
elif [ "$entry_lines" -gt "$max_entry_lines" ]; then
    warning="WARNING: the cross-project index is ${entry_lines} lines (cap ~${max_entry_lines}); routing quality decays past that -- prune or promote entries (see memory-sweep)."
fi
if [ -n "$warning" ]; then
    payload="${warning}

${payload}"
    printf 'memory-loader: %s\n' "$warning" >&2
fi

# Emit exactly one JSON object; escape backslash, quote, tab; join with \n.
# The failure mode of hand-rolled JSON is silent (HOOKS.md lesson) -- the
# test harness pipes this output through a JSON parser.
printf '%s' "$payload" | awk -v event="$event" '
    BEGIN {
        ORS = ""
        print "{\"hookSpecificOutput\":{\"hookEventName\":\"" event "\",\"additionalContext\":\""
    }
    {
        gsub(/\\/, "\\\\")
        gsub(/"/, "\\\"")
        gsub(/\t/, "\\t")
        if (NR > 1) print "\\n"
        print
    }
    END { print "\"}}\n" }
'
exit 0
