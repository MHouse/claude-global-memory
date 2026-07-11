#!/usr/bin/env bash
# Bootstrap the Claude Code cross-project memory system on this machine.
#
# Idempotent setup:
#   1. Creates ~/.claude/memory/ if absent.
#   2. Seeds ~/.claude/memory/MEMORY.md from MEMORY.md.template if absent.
#      If present, compares the *preamble* (everything above '## Entries')
#      against the template and reports drift. The Entries section is
#      per-machine and is never touched.
#   3. Installs the cross-project memory rule to
#      ~/.claude/rules/cross-project-memory.md -- a whole-file managed
#      surface with a .delivered stamp, default ON like the loader: an
#      unmodified-but-stale copy auto-updates on a bare run, an edited one
#      needs --force. Opt out by deleting the file and leaving the stamp in
#      place: bare re-runs respect the deletion; --force reinstalls, and so
#      does a bare run after the stamp is deleted too.
#   4. One-time migration: the rule's content used to live in
#      ~/.claude/CLAUDE.md as a managed '## Cross-project memory' section.
#      A leftover section carrying the bootstrap ownership marker is
#      removed -- silently when it matches the last shipped version
#      (snippets/cross-project-memory-claude-md.md, kept byte-frozen for
#      exactly this comparison), or with a diff + --force when it differs
#      (an older bootstrap's version, or hand edits). A section without
#      the marker is never touched.
#   5. Seeds ~/.claude/hooks/REGISTRY.md (a hooks ledger) from
#      REGISTRY.md.template if absent; else drift-checks its preamble.
#   6. Installs the memory-loader hook (default ON): copies
#      hooks/memory-loader.sh to ~/.claude/hooks/ and registers it in
#      ~/.claude/settings.json under SessionStart + SubagentStart. This is
#      the ONE place bootstrap touches settings.json: the loader's two
#      registration blocks, merged with a real JSON parser; every other key,
#      event, and entry is preserved. The loader injects the '## Entries' of
#      ~/.claude/memory/MEMORY.md into main sessions and non-lean subagents
#      (the script itself skips Explore and Plan). --no-loader skips this
#      run; --uninstall-loader removes it all and opts out of future bare
#      runs; --install-loader opts back in. Also keeps one bootstrap-managed
#      row (first cell 'memory-loader') in the hooks ledger.
#   7. ONLY with --install-skills: copies the bundled skills (closeout,
#      memory-sweep) to ~/.claude/skills/<name>/SKILL.md (whole-file
#      managed surfaces, each with a .delivered stamp so a stale-but-unmodified
#      copy is told apart from an edited one). Default off. Names may follow the
#      flag to select a subset (e.g. --install-skills closeout); omit for all.
#      --uninstall-skills [names] removes them.
#
# Drift = file's managed region differs from canonical content in this
# repo. Default: report with a diff, do not modify. Re-run with --force
# to rewrite drifted regions; customisations inside them are lost,
# customisations outside them are preserved. (One exception: the default-on
# whole-file surfaces -- memory-loader.sh and the cross-project rule --
# auto-update on a bare run when the .delivered stamp proves the copy was
# never hand-edited: load-bearing content, no user edits at risk.)
#
# Flags:
#   --force                Rewrite drifted managed regions with canonical content.
#   --dry-run              Report intended actions, write nothing.
#   --no-loader            Skip memory-loader hook management for this run.
#   --install-loader       Re-enable the memory-loader after --uninstall-loader.
#   --uninstall-loader     Remove the memory-loader hook, its settings.json
#                          registrations, and its ledger row; stays off on
#                          future bare runs until --install-loader.
#   --install-skills [names]    Install bundled skills to ~/.claude/skills/ (omit names for all).
#   --uninstall-skills [names]  Remove installed bundled skills (omit names for all).
#   -h, --help   Show usage.

set -euo pipefail

force=0
dry_run=0
no_loader=0
install_loader=0
uninstall_loader=0
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
        --no-loader)        no_loader=1; shift ;;
        --install-loader)   install_loader=1; shift ;;
        --uninstall-loader) uninstall_loader=1; shift ;;
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
rules_dir="${claude_home}/rules"
rule_source="${repo_root}/rules/cross-project-memory.md"
rule_target="${rules_dir}/cross-project-memory.md"
rule_stamp="${rules_dir}/.cross-project-memory.delivered"
# Byte-frozen: the last-shipped CLAUDE.md section content, used ONLY by the
# step-4 migration comparison. Never edit it; the live content is rules/.
legacy_snippet="${repo_root}/snippets/cross-project-memory-claude-md.md"
hooks_dir="${claude_home}/hooks"
registry="${hooks_dir}/REGISTRY.md"
registry_template="${repo_root}/REGISTRY.md.template"
settings_json="${claude_home}/settings.json"
loader_source="${repo_root}/hooks/memory-loader.sh"
loader_target="${hooks_dir}/memory-loader.sh"
loader_stamp="${hooks_dir}/.memory-loader.delivered"
loader_optout="${hooks_dir}/.memory-loader.optout"
skills_dir="${claude_home}/skills"
# Bundled skills shipped by this repo, installed on demand (see --install-skills).
# Add a skill by dropping skills/<name>/SKILL.md and listing <name> here.
bundled_skills=("closeout" "memory-sweep")

[ -f "$template" ] || { echo "Template not found at $template -- run this script from a clone of the claude-global-memory repo." >&2; exit 1; }
[ -f "$rule_source" ] || { echo "Rule source not found at $rule_source -- run this script from a clone of the claude-global-memory repo." >&2; exit 1; }
[ -f "$legacy_snippet" ] || { echo "Legacy snippet not found at $legacy_snippet -- run this script from a clone of the claude-global-memory repo." >&2; exit 1; }
[ -f "$registry_template" ] || { echo "Registry template not found at $registry_template -- run this script from a clone of the claude-global-memory repo." >&2; exit 1; }
[ -f "$loader_source" ] || { echo "Loader hook source not found at $loader_source -- run this script from a clone of the claude-global-memory repo." >&2; exit 1; }

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

# Remove the '## Cross-project memory' section (H2 through the line before
# the next H2 or EOF) from $file, healing the seam with a single blank line.
# Touches nothing outside the section and its immediate separator blanks.
remove_claudemd_section() {
    local file=$1
    local tmp
    tmp="$(mktemp)"
    awk '
        { lines[NR] = $0 }
        /^## Cross-project memory[[:space:]]*$/ { if (!start) start = NR }
        END {
            if (!start) { for (i = 1; i <= NR; i++) print lines[i]; exit }
            end = NR + 1
            for (i = start + 1; i <= NR; i++) if (lines[i] ~ /^## /) { end = i; break }
            bend = start - 1
            while (bend >= 1 && lines[bend] ~ /^[ \t\r]*$/) bend--
            printed = 0
            for (i = 1; i <= bend; i++) { print lines[i]; printed = 1 }
            if (end <= NR) {
                if (printed) print ""
                for (i = end; i <= NR; i++) print lines[i]
            }
        }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
}

# Portable SHA-256: coreutils `sha256sum` (Linux, Git Bash) or `shasum -a 256`
# (macOS, which ships no sha256sum). Same digest either way. Shared by the
# cross-project rule (step 3), the memory-loader (step 6), and the bundled
# skills (step 7).
_sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; }
# printf '%s' "$(...)" drops the trailing newline so this matches the PowerShell
# Get-NormalizedHash (which joins lines with no trailing newline) byte-for-byte.
normalized_hash() { printf '%s' "$(normalize "$1")" | _sha256 | awk '{print $1}'; }

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
#   - managed surfaces: MEMORY.md preamble, REGISTRY.md preamble, the
#     cross-project rule (default-on whole-file surface + deletion opt-out),
#     and the one-time CLAUDE.md section migration
#   - memory-loader (default-on): script install + stamp + auto-update of
#     unmodified-stale copies, the two-event settings.json merge/uninstall,
#     the ledger row, and the sticky opt-out
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

# 3. Cross-project memory rule -- whole-file surface at
#    ~/.claude/rules/cross-project-memory.md, default ON, stamp semantics
#    like the memory-loader (step 6): an unmodified-but-stale copy
#    auto-updates on a bare run, an edited one needs --force. Deliberate
#    opt-out gesture: the target deleted while the stamp remains means
#    "removed by the user" -- bare re-runs skip it; --force reinstalls,
#    and so does a bare run once the stamp is deleted too.
rule_write() {
    [[ "$dry_run" -eq 1 ]] && return 0
    mkdir -p "$rules_dir"
    # Temp in the SAME dir as the target so the mv is an atomic rename.
    local tmp
    tmp="$(mktemp "${rules_dir}/.cross-project-memory.tmp.XXXXXX")"
    cp "$rule_source" "$tmp" && mv "$tmp" "$rule_target"
    [ -s "$rule_target" ] || { echo "Rule install wrote an empty file at $rule_target" >&2; exit 1; }
    normalized_hash "$rule_source" > "$rule_stamp"
}

manage_rule() {
    if [ -L "$rule_target" ]; then
        note "  WARN      $rule_target is a symlink/junction; not managing it. Remove it first to let bootstrap manage a copy."
        return 0
    fi

    if [ ! -e "$rule_target" ]; then
        if [ -f "$rule_stamp" ]; then
            # File gone, stamp still there: the user deleted it on purpose.
            if [[ "$force" -eq 1 ]]; then
                rule_write
                note "  created   $rule_target (reinstalled)"
            else
                note "  skip      $rule_target (removed by you; --force reinstalls, or delete the stamp $rule_stamp too)"
            fi
        else
            rule_write
            note "  created   $rule_target (cross-project memory rule installed)"
        fi
        return 0
    fi

    local src_hash inst_hash stamp_hash
    src_hash="$(normalized_hash "$rule_source")"
    inst_hash="$(normalized_hash "$rule_target")"
    if [[ "$src_hash" == "$inst_hash" ]]; then
        note "  exists    $rule_target (in sync)"
        return 0
    fi
    stamp_hash=""
    [ -f "$rule_stamp" ] && stamp_hash="$(tr -d '[:space:]' < "$rule_stamp")"
    if [ -n "$stamp_hash" ] && [ "$stamp_hash" == "$inst_hash" ]; then
        # Unmodified since we wrote it: auto-update (default-on surface, same
        # reasoning as the memory-loader -- no user content at risk).
        rule_write
        note "  synced    $rule_target (updated to current version)"
    elif [[ "$force" -eq 1 ]]; then
        rule_write
        note "  synced    $rule_target (overwrote modified copy)"
    else
        note "  DRIFT     $rule_target (differs and looks edited; --force overwrites your changes)"
        drift_reported=1
    fi
}

manage_rule

# 4. One-time migration: remove the superseded '## Cross-project memory'
#    section from ~/.claude/CLAUDE.md (the rule above replaces it). Only a
#    section carrying the bootstrap ownership marker is ever touched;
#    $legacy_snippet is the byte-frozen last-shipped section content used
#    for the comparison. Permanent no-op once the section is gone.
claudemd_ownership_marker='<!-- Section managed by the claude-global-memory bootstrap'
if [ -f "$claude_md" ] && has_section_marker "$claude_md"; then
    live_section="$(extract_claudemd_section "$claude_md")"
    if ! printf '%s\n' "$live_section" | grep -qF "$claudemd_ownership_marker"; then
        note "  WARN      $claude_md (a '## Cross-project memory' section without the bootstrap ownership marker; leaving it -- the canonical content now lives at $rule_target)"
    else
        legacy_section="$(normalize "$legacy_snippet")"
        if [[ "$live_section" == "$legacy_section" ]]; then
            if [[ "$dry_run" -eq 0 ]]; then remove_claudemd_section "$claude_md"; fi
            note "  removed   cross-project memory section from $claude_md (moved to $rule_target)"
        elif [[ "$force" -eq 1 ]]; then
            if [[ "$dry_run" -eq 0 ]]; then remove_claudemd_section "$claude_md"; fi
            note "  removed   cross-project memory section from $claude_md (edited copy deleted; canonical content lives at $rule_target)"
        else
            note "  DRIFT     $claude_md (superseded cross-project memory section differs from the last shipped version -- an older bootstrap or hand edits; review the diff, then re-run with --force to remove it. Canonical content now lives at $rule_target)"
            show_diff "superseded CLAUDE.md section" "$live_section" "$legacy_section"
            drift_reported=1
        fi
    fi
fi

# 5. Hooks registry. Markdown ledger; the memory-loader (step 6) is the only
#    hook this scaffold installs (see HOOKS.md).
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

# 6. Memory-loader hook (default ON; see HOOKS.md "The load-bearing exception").
#    Three surfaces, managed together:
#      (a) ~/.claude/hooks/memory-loader.sh -- whole-file surface with a
#          .delivered stamp, like the bundled skills, EXCEPT an
#          unmodified-but-stale copy auto-updates on a bare run: the bare run
#          is the loader's install gesture, and the stamp proves no user edit
#          is lost. Hand-edited copies still require --force.
#      (b) ~/.claude/settings.json -- the ONE place bootstrap touches it: two
#          registration blocks (hooks.SessionStart + hooks.SubagentStart),
#          merged with a real JSON parser (python3/python), identified by the
#          command containing /hooks/memory-loader.sh. Everything else in the
#          file is preserved; an unparseable file is never touched (WARN +
#          manual instructions). Build-validate-atomic-rename, never in-place.
#      (c) ~/.claude/hooks/REGISTRY.md -- one bootstrap-managed ledger row
#          (first cell 'memory-loader'): added if missing, removed on
#          --uninstall-loader, other rows never touched.
#    --uninstall-loader is sticky (drops .memory-loader.optout) so a later
#    bare re-run doesn't silently resurrect the hook; --install-loader
#    re-enables. --no-loader skips loader management for this run only.

# The registration command string. Absolute path (HOOKS.md: ~ is not reliably
# expanded in settings.json command strings); double quotes so paths with
# spaces survive every shell; forward slashes on Windows (cygpath -m) so the
# same string comes out of bootstrap.sh under Git Bash and bootstrap.ps1.
loader_cmd_path="$loader_target"
if command -v cygpath >/dev/null 2>&1; then
    loader_cmd_path="$(cygpath -m "$loader_target")"
fi
loader_cmd="bash \"${loader_cmd_path}\""

# Flag-neutral so bootstrap.sh and bootstrap.ps1 emit the identical row.
loader_registry_row='| memory-loader | SessionStart + SubagentStart (no matcher) | main-session start/resume/clear/compact + non-lean subagent spawn (script skips Explore, Plan) | the ## Entries section of ~/.claude/memory/MEMORY.md | the index itself | harness injects cross-project memory natively, or uninstall via bootstrap (--uninstall-loader / -UninstallLoader) |'

# A real JSON parser for the settings merge -- never text-munge settings.json.
# The Windows Store python stub exits non-zero on -c, so probe with a real run.
py_bin=""
for _py in python3 python; do
    if command -v "$_py" >/dev/null 2>&1 && "$_py" -c 'import json' >/dev/null 2>&1; then
        py_bin="$_py"
        break
    fi
done

settings_merge() {
    # $1 = check | ensure | remove. Prints one status token:
    #   check  -> ok | absent | partial | drift | invalid
    #   ensure | remove -> changed | unchanged | invalid
    "$py_bin" - "$settings_json" "$loader_cmd" "$1" <<'PYEOF'
import json, os, sys, tempfile

path, cmd, mode = sys.argv[1], sys.argv[2], sys.argv[3]
EVENTS = ("SessionStart", "SubagentStart")
IDENT = "/hooks/memory-loader.sh"

def canonical():
    return {"hooks": [{"type": "command", "command": cmd, "timeout": 10}]}

def is_ours(entry):
    # Either slash style, in case of an old hand-added registration.
    if not isinstance(entry, dict):
        return False
    hooks = entry.get("hooks")
    if not isinstance(hooks, list):
        return False
    return any(
        isinstance(h, dict) and IDENT in (h.get("command") or "").replace("\\", "/")
        for h in hooks
    )

data = {}
if os.path.exists(path):
    try:
        with open(path, encoding="utf-8-sig") as f:
            text = f.read()
    except OSError:
        print("invalid")
        sys.exit(0)
    if text.strip():
        try:
            data = json.loads(text)
        except ValueError:
            print("invalid")
            sys.exit(0)
        if not isinstance(data, dict):
            print("invalid")
            sys.exit(0)

hooks = data.get("hooks")
if hooks is None:
    hooks = {}
if not isinstance(hooks, dict) or any(
    not isinstance(hooks.get(ev), (list, type(None))) for ev in EVENTS
):
    print("invalid")
    sys.exit(0)

if mode == "check":
    states = []
    for ev in EVENTS:
        arr = hooks.get(ev) or []
        ours = [e for e in arr if is_ours(e)]
        if not ours:
            states.append("absent")
        elif len(ours) == 1 and ours[0] == canonical():
            states.append("ok")
        else:
            states.append("drift")
    if "drift" in states:
        print("drift")
    elif states == ["ok", "ok"]:
        print("ok")
    elif states == ["absent", "absent"]:
        print("absent")
    else:
        print("partial")
    sys.exit(0)

changed = False
for ev in EVENTS:
    arr = hooks.get(ev) or []
    kept = [e for e in arr if not is_ours(e)]
    ours = [e for e in arr if is_ours(e)]
    if mode == "ensure":
        if len(ours) == 1 and ours[0] == canonical() and ev in hooks:
            continue
        hooks[ev] = kept + [canonical()]
        changed = True
    else:  # remove
        if not ours:
            continue
        changed = True
        if kept:
            hooks[ev] = kept
        elif ev in hooks:
            del hooks[ev]

if mode == "ensure":
    data["hooks"] = hooks
elif changed and not hooks and "hooks" in data:
    del data["hooks"]

if not changed:
    print("unchanged")
    sys.exit(0)

parent = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(prefix=".settings.tmp.", dir=parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)
except BaseException:
    try:
        os.remove(tmp)
    except OSError:
        pass
    raise
print("changed")
PYEOF
}

loader_write() {
    [[ "$dry_run" -eq 1 ]] && return 0
    mkdir -p "$hooks_dir"
    # Temp in the SAME dir as the target so the mv is an atomic rename.
    local tmp
    tmp="$(mktemp "${hooks_dir}/.memory-loader.tmp.XXXXXX")"
    cp "$loader_source" "$tmp" && mv "$tmp" "$loader_target"
    [ -s "$loader_target" ] || { echo "Loader install wrote an empty file at $loader_target" >&2; exit 1; }
    normalized_hash "$loader_source" > "$loader_stamp"
}

register_loader() {
    if [ -z "$py_bin" ]; then
        note "  WARN      $settings_json (python3/python not found; cannot merge JSON safely -- add the memory-loader registration by hand, see BOOTSTRAP.md)"
        return 0
    fi
    local status existed
    status="$(settings_merge check)"
    case "$status" in
        ok)
            note "  exists    $settings_json (memory-loader registered)"
            ;;
        invalid)
            note "  WARN      $settings_json (not valid JSON; not touching it -- add the memory-loader registration by hand, see BOOTSTRAP.md)"
            ;;
        absent|partial)
            existed=0; [ -f "$settings_json" ] && existed=1
            if [[ "$dry_run" -eq 1 ]]; then
                echo "  [dry-run] would: register memory-loader in $settings_json (SessionStart + SubagentStart)"
            else
                settings_merge ensure >/dev/null
            fi
            if [[ "$existed" -eq 1 ]]; then
                note "  appended  memory-loader registration to $settings_json"
            else
                note "  created   $settings_json (memory-loader registered under SessionStart + SubagentStart)"
            fi
            ;;
        drift)
            if [[ "$force" -eq 1 ]]; then
                if [[ "$dry_run" -eq 0 ]]; then
                    settings_merge ensure >/dev/null
                fi
                note "  synced    $settings_json (memory-loader registration replaced)"
            else
                note "  DRIFT     $settings_json (memory-loader registration differs from canonical; re-run with --force to sync)"
                drift_reported=1
            fi
            ;;
    esac
}

registry_row_present() { [ -f "$registry" ] && grep -q '^| memory-loader |' "$registry"; }

add_registry_row() {
    [ -f "$registry" ] || return 0
    has_marker "$registry" '^## Registered hooks[[:space:]]*$' || return 0
    registry_row_present && return 0
    if [[ "$dry_run" -eq 1 ]]; then
        echo "  [dry-run] would: append memory-loader row to $registry"
    else
        if [ -s "$registry" ] && [ -n "$(tail -c 1 "$registry")" ]; then
            printf '\n' >> "$registry"
        fi
        printf '%s\n' "$loader_registry_row" >> "$registry"
    fi
    note "  appended  memory-loader row to $registry"
}

remove_registry_row() {
    registry_row_present || return 0
    if [[ "$dry_run" -eq 0 ]]; then
        local tmp
        tmp="$(mktemp)"
        grep -v '^| memory-loader |' "$registry" > "$tmp" || true
        mv "$tmp" "$registry"
    fi
    note "  removed   memory-loader row from $registry"
}

manage_loader() {
    local status
    if [[ "$uninstall_loader" -eq 1 ]]; then
        if [ -f "$settings_json" ]; then
            if [ -z "$py_bin" ]; then
                note "  WARN      $settings_json (python3/python not found; remove the memory-loader registration by hand, see BOOTSTRAP.md)"
            else
                status="$(settings_merge check)"
                if [ "$status" = "invalid" ]; then
                    note "  WARN      $settings_json (not valid JSON; remove the memory-loader registration by hand, see BOOTSTRAP.md)"
                elif [ "$status" != "absent" ]; then
                    if [[ "$dry_run" -eq 1 ]]; then
                        echo "  [dry-run] would: remove memory-loader registration from $settings_json"
                    else
                        settings_merge remove >/dev/null
                    fi
                    note "  removed   memory-loader registration from $settings_json"
                fi
            fi
        fi
        if [ -L "$loader_target" ]; then
            if [[ "$dry_run" -eq 0 ]]; then rm -f "$loader_target"; fi
            note "  removed   $loader_target (memory-loader symlink/junction removed; target left untouched)"
        elif [ -e "$loader_target" ]; then
            if [[ "$dry_run" -eq 0 ]]; then rm -f "$loader_target" "$loader_stamp"; fi
            note "  removed   $loader_target (memory-loader uninstalled)"
        else
            note "  skip      memory-loader hook (not installed)"
        fi
        remove_registry_row
        if [[ "$dry_run" -eq 0 ]]; then
            mkdir -p "$hooks_dir"
            : > "$loader_optout"
        fi
        note "  created   $loader_optout (bare re-runs stay opted out; --install-loader re-enables)"
        return 0
    fi

    if [[ "$no_loader" -eq 1 ]]; then
        note "  skip      memory-loader hook (--no-loader)"
        return 0
    fi

    if [ -e "$loader_optout" ]; then
        if [[ "$install_loader" -eq 1 ]]; then
            if [[ "$dry_run" -eq 0 ]]; then rm -f "$loader_optout"; fi
        else
            note "  skip      memory-loader hook (opted out; --install-loader to re-enable)"
            return 0
        fi
    fi

    if [ -L "$loader_target" ]; then
        note "  WARN      $loader_target is a symlink/junction; not managing it. Remove it first to let bootstrap manage a copy."
        return 0
    fi

    # (a) the hook script itself
    if [ ! -e "$loader_target" ]; then
        loader_write
        note "  created   $loader_target (memory-loader hook installed)"
    else
        local src_hash inst_hash stamp_hash
        src_hash="$(normalized_hash "$loader_source")"
        inst_hash="$(normalized_hash "$loader_target")"
        if [[ "$src_hash" == "$inst_hash" ]]; then
            note "  exists    $loader_target (in sync)"
        else
            stamp_hash=""
            [ -f "$loader_stamp" ] && stamp_hash="$(tr -d '[:space:]' < "$loader_stamp")"
            if [ -n "$stamp_hash" ] && [ "$stamp_hash" == "$inst_hash" ]; then
                # Unmodified since we wrote it: auto-update (see block comment).
                loader_write
                note "  synced    $loader_target (updated to current version)"
            elif [[ "$force" -eq 1 ]]; then
                loader_write
                note "  synced    $loader_target (overwrote modified copy)"
            else
                note "  DRIFT     $loader_target (differs and looks edited; --force overwrites your changes)"
                drift_reported=1
            fi
        fi
    fi

    # (b) settings.json registrations
    register_loader

    # (c) ledger row
    add_registry_row
}

manage_loader

# 7. Bundled skills (opt-in). Each is a whole-file managed surface, distinct
#    from the region-based ones above: bootstrap owns the entire SKILL.md,
#    installs it only on --install-skills, and re-syncs only on demand (--force,
#    or an --install-skills re-run for an unmodified-but-stale copy). A
#    .delivered stamp records the normalized hash of what we last wrote, so a
#    stale copy the user never touched is told apart from one they edited. Never
#    writes THROUGH a symlink/junction (that would clobber the link's target).
#    The same logic runs for every skill in $bundled_skills via manage_skill.
#    (_sha256 / normalized_hash are defined above, shared with the loader.)

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
echo "  - Open ~/.claude/rules/cross-project-memory.md and confirm it reads well."
echo "  - Optionally seed ~/.claude/memory/user_identity.md (see BOOTSTRAP.md)."
echo "  - Save memories as you work; the system fills itself."
