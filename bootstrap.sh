#!/usr/bin/env bash
# Bootstrap the Claude Code cross-project memory system on this machine.
#
# Idempotent setup:
#   1. Creates ~/.claude/memory/ if absent.
#   2. Seeds ~/.claude/memory/MEMORY.md from MEMORY.md.template if absent.
#      If present, compares the *preamble* (everything above '## Entries')
#      against the template and reports drift. The Entries section is
#      per-machine and is never touched.
#   3. Creates ~/.claude/CLAUDE.md with a minimal header if absent.
#   4. Appends the cross-project memory section if absent. If present,
#      compares the section body against the snippet and reports drift.
#   5. Seeds ~/.claude/hooks/REGISTRY.md (an empty hooks ledger) from
#      REGISTRY.md.template if absent; else drift-checks its preamble. This
#      is plain Markdown -- NOT a hook, never mutates settings.json. The
#      scaffold installs no hooks.
#   6. ONLY with --install-closeout: copies the bundled closeout skill to
#      ~/.claude/skills/closeout/SKILL.md (a whole-file managed surface, with
#      a .delivered stamp so a stale-but-unmodified copy is told apart from an
#      edited one). Default off. --uninstall-closeout removes it.
#
# Drift = file's managed region differs from canonical content in this
# repo. Default: report with a diff, do not modify. Re-run with --force
# to rewrite drifted regions; customisations inside them are lost,
# customisations outside them are preserved.
#
# Flags:
#   --force                Rewrite drifted managed regions with canonical content.
#   --dry-run              Report intended actions, write nothing.
#   --install-closeout     Install the bundled closeout skill to ~/.claude/skills/.
#   --uninstall-closeout   Remove the installed closeout skill.
#   -h, --help   Show usage.

set -euo pipefail

force=0
dry_run=0
install_closeout=0
uninstall_closeout=0

usage() {
    sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)   force=1; shift ;;
        --dry-run) dry_run=1; shift ;;
        --install-closeout)   install_closeout=1; shift ;;
        --uninstall-closeout) uninstall_closeout=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
claude_home="${HOME}/.claude"
memory_dir="${claude_home}/memory"
memory_index="${memory_dir}/MEMORY.md"
claude_md="${claude_home}/CLAUDE.md"
template="${repo_root}/MEMORY.md.template"
snippet="${repo_root}/snippets/cross-project-memory-claude-md.md"
hooks_dir="${claude_home}/hooks"
registry="${hooks_dir}/REGISTRY.md"
registry_template="${repo_root}/REGISTRY.md.template"
skills_dir="${claude_home}/skills"
closeout_dir="${skills_dir}/closeout"
closeout_target="${closeout_dir}/SKILL.md"
closeout_stamp="${closeout_dir}/.delivered"
closeout_source="${repo_root}/skills/closeout/SKILL.md"

[ -f "$template" ] || { echo "Template not found at $template -- run this script from a clone of the claude-global-memory repo." >&2; exit 1; }
[ -f "$snippet"  ] || { echo "Snippet not found at $snippet -- run this script from a clone of the claude-global-memory repo." >&2; exit 1; }
[ -f "$registry_template" ] || { echo "Registry template not found at $registry_template -- run this script from a clone of the claude-global-memory repo." >&2; exit 1; }

# Normalize: strip CR, strip trailing whitespace per line, strip trailing blank lines.
normalize() {
    local file=$1
    awk '{ sub(/\r$/, ""); sub(/[ \t]+$/, ""); print }' "$file" \
        | awk 'BEGIN{n=0} {a[n++]=$0} END{ while (n>0 && a[n-1]=="") n--; for (i=0;i<n;i++) print a[i] }'
}

# Extract the '## Cross-project memory' section (header through the line
# immediately before the next H2 or EOF). Prints nothing if not found.
extract_claudemd_section() {
    local file=$1
    normalize "$file" | awk '
        /^## Cross-project memory[[:space:]]*$/ { in_section = 1; print; next }
        in_section && /^## / { in_section = 0 }
        in_section { print }
    ' | awk 'BEGIN{n=0} {a[n++]=$0} END{ while (n>0 && a[n-1]=="") n--; for (i=0;i<n;i++) print a[i] }'
}

# Extract a preamble: from start through the line immediately before the
# first line matching $2 (an ERE marker). Prints nothing if marker missing.
# Used for both MEMORY.md ('## Entries') and REGISTRY.md ('## Registered hooks').
extract_preamble() {
    local file=$1
    local marker=$2
    normalize "$file" | awk -v marker="$marker" '
        $0 ~ marker { found=1; exit }
        { print }
        END { if (!found) exit 2 }
    '
}

has_marker() {
    local file=$1
    local marker=$2
    grep -qE "$marker" "$file"
}

has_section_marker() {
    local file=$1
    grep -qE '^## Cross-project memory[[:space:]]*$' "$file"
}

show_diff() {
    local label=$1
    local live=$2
    local canonical=$3
    echo ""
    echo "  ---- diff: $label ----"
    diff -u --label "live"      <(printf '%s\n' "$live") \
            --label "canonical" <(printf '%s\n' "$canonical") || true
    echo "  ---- end diff ----"
    echo ""
}

# Replace lines [start_re, next_h2 or EOF) in $file with contents of $replacement.
replace_claudemd_section() {
    local file=$1
    local replacement=$2  # path to file containing canonical section
    local tmp
    tmp="$(mktemp)"
    awk -v repl_file="$replacement" '
        BEGIN {
            while ((getline line < repl_file) > 0) {
                repl = repl ? repl "\n" line : line
            }
            close(repl_file)
        }
        /^## Cross-project memory[[:space:]]*$/ {
            if (!emitted) {
                print repl
                print ""
                emitted = 1
            }
            skipping = 1
            next
        }
        skipping && /^## / { skipping = 0 }
        !skipping { print }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
}

# Replace the preamble (everything up to the marker line $3) in $file with
# the preamble extracted from $template. Used for MEMORY.md and REGISTRY.md.
replace_preamble() {
    local file=$1
    local template=$2
    local marker=$3
    local tmp
    tmp="$(mktemp)"
    awk -v tpl_file="$template" -v marker="$marker" '
        BEGIN {
            while ((getline line < tpl_file) > 0) {
                if (line ~ marker) { break }
                pre = pre ? pre "\n" line : line
            }
            close(tpl_file)
            # Strip trailing blank lines from preamble
            sub(/\n+$/, "", pre)
        }
        ! shown {
            print pre
            print ""
            shown = 1
        }
        $0 ~ marker { copying = 1 }
        copying { print }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
}

# LOCKSTEP PARITY (bootstrap.sh <-> bootstrap.ps1): these two scripts MUST behave
# identically. Change one => change the other. Operations that must stay in sync:
#   - managed surfaces: MEMORY.md preamble, CLAUDE.md section, REGISTRY.md preamble
#   - closeout skill (opt-in): install / uninstall / whole-file drift report /
#     .delivered stamp / symlink-junction refusal / --force + re-install resync
# Verify BOTH scripts after a change: `bash test/verify.sh` AND
# `pwsh -NoProfile -File test/verify.ps1` (or the manual recipe in BOOTSTRAP.md).
summary=()
drift_reported=0

note() { summary+=("$1"); }
write_action() {
    # $1 = message for dry-run, $2 = command to run
    if [[ "$dry_run" -eq 1 ]]; then
        echo "  [dry-run] would: $1"
    else
        eval "$2"
    fi
}

# 1. Memory directory
if [ ! -d "$memory_dir" ]; then
    if [[ "$dry_run" -eq 0 ]]; then
        mkdir -p "$memory_dir"
    fi
    note "  created   $memory_dir"
else
    note "  exists    $memory_dir"
fi

# 2. MEMORY.md
if [ ! -f "$memory_index" ]; then
    if [[ "$dry_run" -eq 0 ]]; then
        cp "$template" "$memory_index"
    fi
    note "  created   $memory_index (from template)"
else
    if ! has_marker "$memory_index" '^## Entries[[:space:]]*$'; then
        note "  WARN      $memory_index (missing '## Entries' marker; refusing to touch)"
    else
        live_preamble="$(extract_preamble "$memory_index" '^## Entries[[:space:]]*$')"
        tpl_preamble="$(extract_preamble "$template" '^## Entries[[:space:]]*$')"
        if [[ "$live_preamble" == "$tpl_preamble" ]]; then
            note "  exists    $memory_index (preamble matches template)"
        elif [[ "$force" -eq 1 ]]; then
            if [[ "$dry_run" -eq 0 ]]; then
                replace_preamble "$memory_index" "$template" '^## Entries[[:space:]]*$'
            fi
            note "  synced    $memory_index (preamble replaced)"
        else
            note "  DRIFT     $memory_index (preamble differs from template; re-run with --force to sync)"
            show_diff "MEMORY.md preamble" "$live_preamble" "$tpl_preamble"
            drift_reported=1
        fi
    fi
fi

# 3 + 4. CLAUDE.md
if [ ! -f "$claude_md" ]; then
    if [[ "$dry_run" -eq 0 ]]; then
        {
            cat <<'EOF'
# Global CLAUDE.md

Personal preferences and conventions that apply across all projects.
Project-specific guidance lives in each repo's CLAUDE.md.

EOF
            cat "$snippet"
        } > "$claude_md"
    fi
    note "  created   $claude_md (with minimal header + section)"
else
    if ! has_section_marker "$claude_md"; then
        # Append snippet with a blank-line separator.
        if [[ "$dry_run" -eq 0 ]]; then
            # Ensure trailing newline before appending
            if [ -s "$claude_md" ] && [ "$(tail -c 1 "$claude_md" | wc -c)" -gt 0 ]; then
                printf '\n' >> "$claude_md"
            fi
            printf '\n' >> "$claude_md"
            cat "$snippet" >> "$claude_md"
            last_char="$(tail -c 1 "$claude_md")"
            [ -n "$last_char" ] && printf '\n' >> "$claude_md"
        fi
        note "  appended  cross-project memory section to $claude_md"
    else
        live_section="$(extract_claudemd_section "$claude_md")"
        canonical_section="$(normalize "$snippet")"
        if [[ "$live_section" == "$canonical_section" ]]; then
            note "  exists    $claude_md (section matches canonical snippet)"
        elif [[ "$force" -eq 1 ]]; then
            if [[ "$dry_run" -eq 0 ]]; then
                replace_claudemd_section "$claude_md" "$snippet"
            fi
            note "  synced    $claude_md (section replaced)"
        else
            note "  DRIFT     $claude_md (section differs from snippet; re-run with --force to sync)"
            show_diff "CLAUDE.md cross-project section" "$live_section" "$canonical_section"
            drift_reported=1
        fi
    fi
fi

# 5. Hooks registry. Markdown ledger ONLY -- this is never a hook and never
#    mutates settings.json; the scaffold installs no hooks (see HOOKS.md).
if [ ! -d "$hooks_dir" ]; then
    if [[ "$dry_run" -eq 0 ]]; then
        mkdir -p "$hooks_dir"
    fi
    note "  created   $hooks_dir"
else
    note "  exists    $hooks_dir"
fi

if [ ! -f "$registry" ]; then
    if [[ "$dry_run" -eq 0 ]]; then
        cp "$registry_template" "$registry"
    fi
    note "  created   $registry (from template)"
else
    if ! has_marker "$registry" '^## Registered hooks[[:space:]]*$'; then
        note "  WARN      $registry (missing '## Registered hooks' marker; refusing to touch)"
    else
        live_reg_preamble="$(extract_preamble "$registry" '^## Registered hooks[[:space:]]*$')"
        tpl_reg_preamble="$(extract_preamble "$registry_template" '^## Registered hooks[[:space:]]*$')"
        if [[ "$live_reg_preamble" == "$tpl_reg_preamble" ]]; then
            note "  exists    $registry (preamble matches template)"
        elif [[ "$force" -eq 1 ]]; then
            if [[ "$dry_run" -eq 0 ]]; then
                replace_preamble "$registry" "$registry_template" '^## Registered hooks[[:space:]]*$'
            fi
            note "  synced    $registry (preamble replaced)"
        else
            note "  DRIFT     $registry (preamble differs from template; re-run with --force to sync)"
            show_diff "REGISTRY.md preamble" "$live_reg_preamble" "$tpl_reg_preamble"
            drift_reported=1
        fi
    fi
fi

# 6. Closeout skill (opt-in). A whole-file managed surface, distinct from the
#    region-based ones above: bootstrap owns the entire SKILL.md, installs it
#    only on --install-closeout, and re-syncs only on demand (--force, or an
#    --install-closeout re-run for an unmodified-but-stale copy). A .delivered
#    stamp records the normalized hash of what we last wrote, so a stale copy
#    the user never touched is told apart from one they edited. Never writes
#    THROUGH a symlink/junction (that would clobber the link's target).
# Portable SHA-256: coreutils `sha256sum` (Linux, Git Bash) or `shasum -a 256`
# (macOS, which ships no sha256sum). Same digest either way.
_sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; }
# printf '%s' "$(...)" drops the trailing newline so this matches the PowerShell
# Get-NormalizedHash (which joins lines with no trailing newline) byte-for-byte.
normalized_hash() { printf '%s' "$(normalize "$1")" | _sha256 | awk '{print $1}'; }
closeout_write() {
    # Copy source -> target atomically, refresh the stamp. Honors dry-run.
    [[ "$dry_run" -eq 1 ]] && return 0
    mkdir -p "$closeout_dir"
    # Temp in the SAME dir as the target so the mv is a same-filesystem rename
    # (atomic), not a cross-fs copy+unlink that could leave a torn file.
    local tmp; tmp="$(mktemp "${closeout_dir}/.SKILL.tmp.XXXXXX")"
    cp "$closeout_source" "$tmp" && mv "$tmp" "$closeout_target"
    [ -s "$closeout_target" ] || { echo "Closeout install wrote an empty file at $closeout_target" >&2; exit 1; }
    normalized_hash "$closeout_source" > "$closeout_stamp"
}

if [[ "$uninstall_closeout" -eq 1 ]]; then
    if [ -L "$closeout_dir" ]; then
        # Remove only the link, never recurse into (and delete) its target.
        if [[ "$dry_run" -eq 0 ]]; then rm -f "$closeout_dir"; fi
        note "  removed   $closeout_dir (closeout symlink/junction removed; target left untouched)"
    elif [ -e "$closeout_target" ] || [ -e "$closeout_dir" ]; then
        # Remove only what we installed; rmdir only if the dir is now empty so we
        # never clobber files the user added under the skill directory.
        if [[ "$dry_run" -eq 0 ]]; then
            rm -f "$closeout_target" "$closeout_stamp"
            rmdir "$closeout_dir" 2>/dev/null || true
        fi
        note "  removed   $closeout_target (closeout uninstalled)"
    else
        note "  skip      closeout skill (not installed)"
    fi
elif [ -L "$closeout_dir" ] || [ -L "$closeout_target" ]; then
    note "  WARN      $closeout_dir is a symlink/junction; not managing it. Remove it first to let bootstrap manage a copy."
elif [ ! -e "$closeout_target" ]; then
    if [[ "$install_closeout" -eq 1 ]]; then
        [ -f "$closeout_source" ] || { echo "Closeout source not found at $closeout_source -- run from a clone of the repo." >&2; exit 1; }
        closeout_write
        note "  created   $closeout_target (closeout installed)"
    else
        note "  skip      closeout skill (not installed; --install-closeout to add)"
    fi
else
    [ -f "$closeout_source" ] || { echo "Closeout source not found at $closeout_source -- run from a clone of the repo." >&2; exit 1; }
    src_hash="$(normalized_hash "$closeout_source")"
    inst_hash="$(normalized_hash "$closeout_target")"
    if [[ "$src_hash" == "$inst_hash" ]]; then
        note "  exists    $closeout_target (in sync)"
    else
        stamp_hash=""
        [ -f "$closeout_stamp" ] && stamp_hash="$(tr -d '[:space:]' < "$closeout_stamp")"
        if [ -n "$stamp_hash" ] && [ "$stamp_hash" == "$inst_hash" ]; then
            # Unmodified since we wrote it, but the repo moved forward.
            if [[ "$install_closeout" -eq 1 || "$force" -eq 1 ]]; then
                closeout_write
                note "  synced    $closeout_target (updated to current version)"
            else
                note "  DRIFT     $closeout_target (newer version available; your copy is unmodified -- --install-closeout or --force to update)"
                drift_reported=1
            fi
        else
            # User-edited (or no stamp to prove otherwise): never clobber without --force.
            if [[ "$force" -eq 1 ]]; then
                closeout_write
                note "  synced    $closeout_target (overwrote modified copy)"
            else
                note "  DRIFT     $closeout_target (differs and looks edited; --force overwrites your changes)"
                drift_reported=1
            fi
        fi
    fi
fi

echo ""
echo "Bootstrap complete."
echo ""
echo "Summary:"
for item in "${summary[@]}"; do
    echo "$item"
done
echo ""
if [[ "$drift_reported" -eq 1 ]]; then
    cat <<'EOF'
Drift detected. Re-run with --force to overwrite the drifted regions with the
canonical content shipped in this repo. Hand-customisations inside those
regions will be lost; customisations outside them are preserved.

EOF
fi
echo "Next steps:"
echo "  - Open ~/.claude/CLAUDE.md and confirm the section reads well."
echo "  - Optionally seed ~/.claude/memory/user_identity.md (see BOOTSTRAP.md)."
echo "  - Save memories as you work; the system fills itself."
