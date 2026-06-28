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
#   6. ONLY with --install-skills: copies the bundled skills (closeout,
#      memory-sweep) to ~/.claude/skills/<name>/SKILL.md (whole-file
#      managed surfaces, each with a .delivered stamp so a stale-but-unmodified
#      copy is told apart from an edited one). Default off. Names may follow the
#      flag to select a subset (e.g. --install-skills closeout); omit for all.
#      --uninstall-skills [names] removes them.
#
# Drift = file's managed region differs from canonical content in this
# repo. Default: report with a diff, do not modify. Re-run with --force
# to rewrite drifted regions; customisations inside them are lost,
# customisations outside them are preserved.
#
# Flags:
#   --force                Rewrite drifted managed regions with canonical content.
#   --dry-run              Report intended actions, write nothing.
#   --install-skills [names]    Install bundled skills to ~/.claude/skills/ (omit names for all).
#   --uninstall-skills [names]  Remove installed bundled skills (omit names for all).
#   -h, --help   Show usage.

set -euo pipefail

force=0
dry_run=0
install_skills=0
uninstall_skills=0
skill_filter=()

usage() {
    sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)   force=1; shift ;;
        --dry-run) dry_run=1; shift ;;
        --install-skills)
            install_skills=1; shift
            while [[ $# -gt 0 && "$1" != -* ]]; do skill_filter+=("$1"); shift; done
            ;;
        --uninstall-skills)
            uninstall_skills=1; shift
            while [[ $# -gt 0 && "$1" != -* ]]; do skill_filter+=("$1"); shift; done
            ;;
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
# Bundled skills shipped by this repo, installed on demand (see --install-skills).
# Add a skill by dropping skills/<name>/SKILL.md and listing <name> here.
bundled_skills=("closeout" "memory-sweep")

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
#   - bundled skills (opt-in): install / uninstall / whole-file drift report /
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

# 6. Bundled skills (opt-in). Each is a whole-file managed surface, distinct
#    from the region-based ones above: bootstrap owns the entire SKILL.md,
#    installs it only on --install-skills, and re-syncs only on demand (--force,
#    or an --install-skills re-run for an unmodified-but-stale copy). A
#    .delivered stamp records the normalized hash of what we last wrote, so a
#    stale copy the user never touched is told apart from one they edited. Never
#    writes THROUGH a symlink/junction (that would clobber the link's target).
#    The same logic runs for every skill in $bundled_skills via manage_skill.
# Portable SHA-256: coreutils `sha256sum` (Linux, Git Bash) or `shasum -a 256`
# (macOS, which ships no sha256sum). Same digest either way.
_sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; }
# printf '%s' "$(...)" drops the trailing newline so this matches the PowerShell
# Get-NormalizedHash (which joins lines with no trailing newline) byte-for-byte.
normalized_hash() { printf '%s' "$(normalize "$1")" | _sha256 | awk '{print $1}'; }

# Is $1 selected by the optional skill filter? Empty filter = all bundled skills.
skill_selected() {
    local name=$1 s
    [ ${#skill_filter[@]} -eq 0 ] && return 0
    for s in "${skill_filter[@]}"; do [ "$s" == "$name" ] && return 0; done
    return 1
}

skill_write() {
    # $1 = skill name. Copy source -> target atomically, refresh the stamp. Honors dry-run.
    local name=$1
    local dir="${skills_dir}/${name}"
    local target="${dir}/SKILL.md"
    local stamp="${dir}/.delivered"
    local source="${repo_root}/skills/${name}/SKILL.md"
    [[ "$dry_run" -eq 1 ]] && return 0
    mkdir -p "$dir"
    # Temp in the SAME dir as the target so the mv is a same-filesystem rename
    # (atomic), not a cross-fs copy+unlink that could leave a torn file.
    local tmp; tmp="$(mktemp "${dir}/.SKILL.tmp.XXXXXX")"
    cp "$source" "$tmp" && mv "$tmp" "$target"
    [ -s "$target" ] || { echo "Skill install wrote an empty file at $target" >&2; exit 1; }
    normalized_hash "$source" > "$stamp"
}

manage_skill() {
    local name=$1
    local dir="${skills_dir}/${name}"
    local target="${dir}/SKILL.md"
    local stamp="${dir}/.delivered"
    local source="${repo_root}/skills/${name}/SKILL.md"

    if [[ "$uninstall_skills" -eq 1 ]] && skill_selected "$name"; then
        if [ -L "$dir" ]; then
            # Remove only the link, never recurse into (and delete) its target.
            if [[ "$dry_run" -eq 0 ]]; then rm -f "$dir"; fi
            note "  removed   $dir ($name symlink/junction removed; target left untouched)"
        elif [ -e "$target" ] || [ -e "$dir" ]; then
            # Remove only what we installed; rmdir only if the dir is now empty so we
            # never clobber files the user added under the skill directory.
            if [[ "$dry_run" -eq 0 ]]; then
                rm -f "$target" "$stamp"
                rmdir "$dir" 2>/dev/null || true
            fi
            note "  removed   $target ($name uninstalled)"
        else
            note "  skip      $name skill (not installed)"
        fi
        return 0
    fi

    if [ -L "$dir" ] || [ -L "$target" ]; then
        note "  WARN      $dir is a symlink/junction; not managing it. Remove it first to let bootstrap manage a copy."
        return 0
    fi

    [ -f "$source" ] || { echo "Skill source not found at $source -- run from a clone of the repo." >&2; exit 1; }

    if [ ! -e "$target" ]; then
        if [[ "$install_skills" -eq 1 ]] && skill_selected "$name"; then
            skill_write "$name"
            note "  created   $target ($name installed)"
        else
            note "  skip      $name skill (not installed; --install-skills to add)"
        fi
        return 0
    fi

    # Installed: report drift, re-sync only on demand.
    local src_hash inst_hash stamp_hash
    src_hash="$(normalized_hash "$source")"
    inst_hash="$(normalized_hash "$target")"
    if [[ "$src_hash" == "$inst_hash" ]]; then
        note "  exists    $target (in sync)"
        return 0
    fi
    stamp_hash=""
    [ -f "$stamp" ] && stamp_hash="$(tr -d '[:space:]' < "$stamp")"
    if [ -n "$stamp_hash" ] && [ "$stamp_hash" == "$inst_hash" ]; then
        # Unmodified since we wrote it, but the repo moved forward.
        if { [[ "$install_skills" -eq 1 ]] && skill_selected "$name"; } || [[ "$force" -eq 1 ]]; then
            skill_write "$name"
            note "  synced    $target (updated to current version)"
        else
            note "  DRIFT     $target (newer version available; your copy is unmodified -- --install-skills or --force to update)"
            drift_reported=1
        fi
    else
        # User-edited (or no stamp to prove otherwise): never clobber without --force.
        if [[ "$force" -eq 1 ]]; then
            skill_write "$name"
            note "  synced    $target (overwrote modified copy)"
        else
            note "  DRIFT     $target (differs and looks edited; --force overwrites your changes)"
            drift_reported=1
        fi
    fi
}

for _skill in "${bundled_skills[@]}"; do
    manage_skill "$_skill"
done

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
