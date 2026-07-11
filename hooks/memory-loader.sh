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
# Keep in sync with the filter documented in BOOTSTRAP.md. This is the
# DEFAULT -- override it in ~/.claude/hooks/memory-loader.conf (parsed
# below), never by editing this file: an edit marks the managed script
# user-modified and blocks auto-update (BOOTSTRAP.md, drift table).
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

# Git Bash launched outside a login shell may lack HOME; fall back to the
# Windows profile.
home_dir="${HOME:-${USERPROFILE:-}}"
[ -n "$home_dir" ] || exit 0

# Optional user config, one supported key:
#   skip_agent_types="Explore Plan SomeNewLeanType"
# The value REPLACES the default above (use a placeholder like "none" to skip
# no types). Parsed -- not sourced -- so a broken conf can't kill injection
# and Windows CRLF is tolerated. The conf is user territory: bootstrap never
# writes, stamps, force-overwrites, or uninstalls it, which is the point --
# configuring the loader here keeps this script pristine and auto-updating.
conf="${home_dir}/.claude/hooks/memory-loader.conf"
if [ -f "$conf" ]; then
    conf_skip=$(sed -n 's/^[[:space:]]*skip_agent_types=//p' "$conf" | tail -n 1 | tr -d '"\047\r')
    [ -n "$conf_skip" ] && skip_agent_types="$conf_skip"
fi

# SubagentStart carries agent_type; if a SessionStart payload ever carries one
# (SDK contexts), the same skip applies.
agent_type=$(field agent_type)
if [ -n "$agent_type" ]; then
    for t in $skip_agent_types; do
        [ "$agent_type" = "$t" ] && exit 0
    done
fi

index="${home_dir}/.claude/memory/MEMORY.md"
[ -f "$index" ] || exit 0

# Everything below the '## Entries' marker. Empty index -> inject nothing
# (fresh installs cost zero tokens).
entries=$(awk '/^## Entries[[:space:]]*$/ { found=1; next } found { sub(/\r$/, ""); print }' "$index")
[ -n "$(printf '%s' "$entries" | tr -d '[:space:]')" ] || exit 0

# --- the fold ---------------------------------------------------------------
# An optional standalone '<!-- fold -->' line inside ## Entries splits the
# index into an ambient above-fold segment and an on-demand tail (see
# BOOTSTRAP.md, "The memory-loader hook"). Strict grammar: the whole line,
# surrounding whitespace allowed, CR already stripped by the extraction --
# marker text inside an entry line is data, not a marker. The first marker
# wins; extras are reported on stderr. A marker with an empty tail withholds
# nothing. No marker = the pre-fold behavior, byte for byte.
fold_re='^[[:space:]]*<!-- fold -->[[:space:]]*$'
fold_line=$(printf '%s\n' "$entries" | grep -nE "$fold_re" | head -n 1 | cut -d: -f1)
above=""; below=""
if [ -n "$fold_line" ]; then
    fold_count=$(printf '%s\n' "$entries" | grep -cE "$fold_re")
    [ "$fold_count" -gt 1 ] && printf 'memory-loader: %s fold markers found; using the first\n' "$fold_count" >&2
    above=$(printf '%s\n' "$entries" | awk -v m="$fold_line" 'NR < m')
    below=$(printf '%s\n' "$entries" | awk -v m="$fold_line" 'NR > m')
    [ -n "$(printf '%s' "$below" | tr -d '[:space:]')" ] || fold_line=""
fi

# Mode selection: with a marker, subagents always get the ambient segment
# only -- they multiply injection cost under fan-out and inherit the global
# CLAUDE.md retrieval fallback. Main sessions get the full index while it
# fits the byte budget; past it they auto-degrade to the ambient segment
# instead of letting the harness truncate silently (the sentinel then says
# what was withheld, and the CLAUDE.md snippet knows partial != truncated).
full_inject=$(printf '%s\n' "$entries" | grep -vE "$fold_re")
mode=full
if [ -n "$fold_line" ]; then
    if [ "$event" = "SubagentStart" ]; then
        mode=fold
    elif [ "$(printf '%s' "$full_inject" | wc -c | tr -d '[:space:]')" -gt "$max_entry_bytes" ]; then
        mode=fold
        printf 'memory-loader: index past the %s-byte budget; injecting above-fold only\n' "$max_entry_bytes" >&2
    fi
fi

if [ "$mode" = "fold" ]; then
    inject="$above"
    if [ -n "$(printf '%s' "$above" | tr -d '[:space:]')" ]; then
        entry_lines=$(printf '%s\n' "$above" | wc -l | tr -d '[:space:]')
        entry_bytes=$(printf '%s' "$above" | wc -c | tr -d '[:space:]')
    else
        entry_lines=0; entry_bytes=0
        printf 'memory-loader: above-fold segment is empty; subagents get only the pointer\n' >&2
    fi
    below_lines=$(printf '%s\n' "$below" | wc -l | tr -d '[:space:]')
else
    # Marker lines are stripped from a full injection -- structure, not
    # content. Without a marker this is the identity transform.
    inject="$full_inject"
    entry_lines=$(printf '%s\n' "$inject" | wc -l | tr -d '[:space:]')
    entry_bytes=$(printf '%s' "$inject" | wc -c | tr -d '[:space:]')
fi

payload="Cross-project memory index -- injected from ~/.claude/memory/MEMORY.md (see ~/.claude/rules/cross-project-memory.md). One line per entry; read the linked entry file under ~/.claude/memory/ before acting on one.

$inject"

# Budget warnings, named for the segment they measure -- a fold changes which
# bytes are always-resident, and a warning must say which segment blew which
# budget or the user fixes the wrong one.
warning=""
if [ "$mode" = "fold" ]; then
    if [ "$entry_bytes" -gt "$max_entry_bytes" ]; then
        warning="WARNING: the ABOVE-FOLD segment alone is ${entry_bytes} bytes -- past the ~${max_entry_bytes}-byte injection budget, so the fold is not doing its job; move entries below the fold or trim them (see memory-sweep)."
    fi
elif [ "$entry_bytes" -gt "$max_entry_bytes" ]; then
    warning="WARNING: the cross-project index is ${entry_bytes} bytes; the harness keeps only a ~2KB preview of injections past ~10k characters, so entries below the fold lose the always-in-context guarantee -- trim or promote (see memory-sweep) and keep imperative lines at the top."
elif [ "$entry_lines" -gt "$max_entry_lines" ]; then
    warning="WARNING: the cross-project index is ${entry_lines} lines (cap ~${max_entry_lines}); routing quality decays past that -- prune or promote entries (see memory-sweep)."
fi
if [ -n "$warning" ]; then
    payload="${warning}

${payload}"
    printf 'memory-loader: %s\n' "$warning" >&2
fi

# Terminal sentinel: the harness truncates oversized injections silently and
# its threshold is undocumented and version-dependent, so DETECT rather than
# predict -- the CLAUDE.md snippet treats a payload whose final INDEX-END line
# is missing as truncated and falls back to reading the file. The prefix
# 'INDEX-END (N lines, N bytes' is a stable contract for deployed consumers;
# fold mode appends the withheld-tail pointer after it.
if [ "$mode" = "fold" ]; then
    payload="${payload}

INDEX-END (${entry_lines} lines, ${entry_bytes} bytes; ${below_lines} lines below the fold -- read ~/.claude/memory/MEMORY.md)"
else
    payload="${payload}

INDEX-END (${entry_lines} lines, ${entry_bytes} bytes)"
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
