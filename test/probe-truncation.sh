#!/usr/bin/env bash
# probe-truncation.sh: re-measure the harness's injected-context truncation
# threshold. The harness silently truncates oversized hook injections to a
# ~2KB preview past an undocumented, version-dependent bound (~10k chars when
# probe-measured on CLI 2.1.204) -- the bound the memory-loader's
# max_entry_bytes warning is calibrated against. Run this when a session
# reports the index block lost its INDEX-END sentinel (the CLAUDE.md
# snippet's truncation alarm), or out of curiosity after a CLI update.
#
# Method: temporarily swap ~/.claude/memory/MEMORY.md for synthetic indexes
# of known '## Entries' sizes, start one headless session per size (the real
# installed loader injects them), and ask the model for the final line of the
# injected block. INDEX-END survived = below the threshold; missing =
# truncated. The live index is restored on exit via trap; if the store is a
# git repo (see BOOTSTRAP.md maintenance notes), history is a second net.
#
# Deliberately MANUAL -- not part of verify.sh/CI:
#   - needs a logged-in `claude` CLI on PATH and spends a few cents of tokens
#     (one short session per size)
#   - sessions you start while it runs will see the synthetic index
#   - the threshold applies to the whole injected payload, which is the
#     entries plus ~100-500 bytes of header/warning/sentinel -- this brackets,
#     it doesn't measure to the byte
#
# Usage: bash test/probe-truncation.sh [sizes...]   (default: 8000 10000 12000)

set -u

sizes=${*:-"8000 10000 12000"}
home_dir="${HOME:-${USERPROFILE:-}}"
index="${home_dir}/.claude/memory/MEMORY.md"
hook="${home_dir}/.claude/hooks/memory-loader.sh"

command -v claude >/dev/null 2>&1 || { echo "claude CLI not on PATH" >&2; exit 2; }
[ -f "$hook" ] || { echo "memory-loader not installed at $hook -- nothing to probe" >&2; exit 2; }
[ -f "$index" ] || { echo "no index at $index" >&2; exit 2; }

backup=$(mktemp) || exit 2
cp "$index" "$backup" || exit 2
restore() {
    cp "$backup" "$index" && rm -f "$backup" && echo "live index restored"
}
trap restore EXIT INT TERM
echo "live index backed up to $backup (auto-restored on exit)"

line='- [probe entry](probe.md) -- synthetic filler for the truncation probe xxxxxxxxxxx'
for target in $sizes; do
    {
        printf '# Cross-Project Memory Index (truncation probe)\n\n## Entries\n\n'
        n=$(( target / ( ${#line} + 1 ) ))
        i=0
        while [ "$i" -lt "$n" ]; do printf '%s\n' "$line"; i=$((i+1)); done
    } > "$index"
    actual=$(awk '/^## Entries[[:space:]]*$/ { f=1; next } f' "$index" | wc -c | tr -d '[:space:]')
    out=$(claude -p "Print the exact final line of the 'Cross-project memory index' block currently in your context. If no such block is in context, print exactly ABSENT. Print nothing else." 2>/dev/null)
    case "$out" in
        *INDEX-END*) verdict="intact";;
        *ABSENT*)    verdict="ABSENT (loader not firing? check settings.json registration)";;
        *)           verdict="TRUNCATED";;
    esac
    printf '%7s entry bytes -> %s\n' "$actual" "$verdict"
done

echo
echo "The threshold sits between the largest 'intact' and the smallest"
echo "'TRUNCATED' size (rerun with custom sizes to tighten the bracket)."
echo "If it moved: re-calibrate max_entry_bytes in hooks/memory-loader.sh and"
echo "the ~9KB doc mentions -- the lockstep greps in test/verify.sh list them."
