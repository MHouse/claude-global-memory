# Hooks: the rare justified exception

**This scaffold installs no hooks and never edits `settings.json`.** The default
way to raise the salience of a memory is an *imperative index line* (see
`MEMORY.md.template` → "Index-line salience"). A `PreToolUse` hook is the
heavier alternative, reserved for the few cases where an index line provably
can't do the job at the moment of need.

This file documents *when* a hook is justified, *how* to add one safely, and how
to keep the ledger (`~/.claude/hooks/REGISTRY.md`, seeded by bootstrap). A hook
is **integration plumbing, governed like code** — not a memory entry.

## When a hook is allowed (admission policy)

Before adding a hook, **all six** must hold — otherwise sharpen the index line
instead:

1. **Exact, tool-level trigger** — matchable on a tool name / payload, not a
   semantic "this topic came up" judgment.
2. **Costly miss** — destructive action, failed connection, credential/auth
   churn, data-loss risk, or repeated wasted turns. Not "agent forgot a
   preference."
3. **Minimum actionable fact injected** — the one command/recipe, not a whole
   runbook (point at the owning memory file for the rest).
4. **Named source of truth + intentional duplication** — the owning memory file
   is canon; the hook's copy is a deliberate duplicate, flagged to keep in sync.
5. **No general mechanism would enforce it at the right moment** — a blanket
   session-start loader that only re-injects the index does NOT count. If the
   failure is "didn't dereference the right entry at the action point," a
   broader loader is a placebo.
6. **Reviewed as infrastructure, not memory** — governed like code, with a
   removal criterion.

**No new hook without a postmortem** showing why an imperative index line /
routing can't reliably solve it at the moment of need. Every hook gets a row in
`~/.claude/hooks/REGISTRY.md`.

## How `PreToolUse` hooks work

- The **`matcher` in `settings.json` matches the *tool name* only** — a regex
  like `Skill`, `Bash`, `Edit`, or an MCP name `mcp__server__tool`. It cannot
  look inside the arguments.
- When the hook fires, it receives JSON on stdin with `tool_name` and
  `tool_input`. **`tool_input`'s shape differs per tool** — match the one field
  that identifies your case:

  | Tool | `matcher` | Identifying field in `tool_input` |
  |---|---|---|
  | `Skill` | `Skill` | `.skill` (plus `.args`) |
  | `Bash` | `Bash` | `.command` |
  | `Edit` / `Write` | `Edit` | `.file_path` (plus content) |
  | `Read` | `Read` | `.file_path` |
  | MCP tool | `mcp__server__tool` | tool-specific |

- **Scope the match to that field, never the whole raw payload.** A
  whole-payload grep false-positives when your needle appears in *another*
  tool's arguments (e.g. a `Bash` command or a skill `args` string that merely
  *mentions* it).
- **Subset vs. all:** if the hook should fire for *every* call of a tool, the
  `matcher` alone suffices and the script always injects. The field test is only
  for firing on a *subset* (one skill, one command pattern, one path).
- **To inject context**, print exactly one line of JSON to stdout:
  `{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"…"}}`.
  Exit 0. (Exit 2 blocks the tool; only stderr is read then.)
- **Hooks hot-reload** — editing `settings.json` takes effect on the next tool
  call, no restart.

## Adding a hook — the 3-step recipe

### Step 1 — Write the hook script (`~/.claude/hooks/<name>.sh`)

Portable POSIX `sh` + `grep`; no `jq`. Runs identically on macOS, Linux, and Git
Bash on Windows — the script never differs by OS (only its invocation does, in
Step 2).

```bash
#!/usr/bin/env bash
# PreToolUse hook: inject <FACT> when <TOOL> is called for <SPECIFIC CASE>.
# Adapter shim / guardrail, governed like code (see HOOKS.md). NOT memory.
# Owning memory file: <path>.  Registered in: ~/.claude/hooks/REGISTRY.md

input=$(cat)

# Match ONLY the identifying field for this tool (see the table above), never
# the whole payload. Examples:
#   Skill -> '"skill"[[:space:]]*:[[:space:]]*"[^"]*<NEEDLE>'
#   Bash  -> '"command"[[:space:]]*:[[:space:]]*"[^"]*<NEEDLE>'
if printf '%s' "$input" | grep -Eq '"skill"[[:space:]]*:[[:space:]]*"[^"]*<NEEDLE>'; then
  # The line below MUST be valid JSON. A single stray unescaped quote (e.g. a
  # closing \" where you meant ") silently breaks it. Validate (Step 1b).
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"<MINIMUM ACTIONABLE FACT — point at the owning memory file for the rest>"}}
JSON
fi

exit 0
```

**Step 1b — validate the JSON before you trust it** (the failure mode is silent):

```bash
printf '%s' '{"tool_name":"Skill","tool_input":{"skill":"<NEEDLE>"}}' \
  | bash ~/.claude/hooks/<name>.sh | python -m json.tool >/dev/null && echo OK
# Also confirm it stays SILENT when the needle is only in another field:
printf '%s' '{"tool_name":"Skill","tool_input":{"skill":"other","args":"<NEEDLE>"}}' \
  | bash ~/.claude/hooks/<name>.sh   # should print nothing
```

### Step 2 — Register it in `settings.json`

Merge this into `~/.claude/settings.json` (add to the existing `hooks` object if
present; don't clobber other events). The `matcher` is the tool name:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Skill",
        "hooks": [
          { "type": "command", "command": "<INVOCATION — see below>" }
        ]
      }
    ]
  }
}
```

**Invoking the hook (per platform)** — only this string differs by OS; use an
**absolute path** everywhere (`~` is not reliably expanded inside a
`settings.json` command string on any OS):

- **macOS / Linux:** `chmod +x ~/.claude/hooks/<name>.sh`, then
  `command`: `/Users/<you>/.claude/hooks/<name>.sh`
- **Windows (Git Bash):**
  `command`: `bash 'C:/Users/<you>/.claude/hooks/<name>.sh'`

Then validate the file is still valid JSON:
`python -m json.tool < ~/.claude/settings.json >/dev/null && echo OK`.

### Step 3 — Add a row to `~/.claude/hooks/REGISTRY.md`

Under `## Registered hooks`: the hook, its event/matcher, trigger, what it
injects, the owning memory file, and the **removal criteria** (the condition
under which this hook should be deleted).

## Removing a hook

Delete its row in `REGISTRY.md`, its block in `settings.json`, and the script.
If it duplicated a fact from a memory file, that file remains the source of
truth — leave it.

## Lessons baked in (so they aren't rediscovered)

- **Match the identifying field, not the whole payload** — a raw grep matched a
  string sitting in a *different* tool's args and fired a false positive.
- **Hook output must be valid JSON** — a stray escaped quote closing the string
  early breaks it silently; always run the Step 1b validator.
- **`matcher` is tool-name only** — narrowing to a specific skill/command/path
  happens in the script, not the matcher.
- **Hooks hot-reload** — no restart needed to test a change.
