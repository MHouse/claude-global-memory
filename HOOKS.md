# Hooks: the load-bearing loader, and the rare guardrail exception

**This scaffold ships exactly one hook — the memory-loader — and bootstrap
touches `settings.json` only to register it.** Everything else stays out: the
default way to raise the salience of a memory is an *imperative index line*
(see `MEMORY.md.template` → "Index-line salience"). A `PreToolUse` guardrail
hook is the heavier alternative, reserved for the few cases where an index
line provably can't do the job at the moment of need.

This file documents the loader (and why it's a different category), *when* a
guardrail hook is justified, *how* to add one safely, and how to keep the
ledger (`~/.claude/hooks/REGISTRY.md`, seeded by bootstrap). A hook is
**integration plumbing, governed like code** — not a memory entry.

## The load-bearing exception: the memory-loader

The loader is not a guardrail; it is the cross-project layer's **load
mechanism**. Before it existed, loading the index depended on a CLAUDE.md
instruction — model-followed, probabilistic — while the per-project layer is
harness-injected — mechanical. A 2026-07 postmortem documents the failure
class that asymmetry produces: a session never loaded the index, so an
imperative index line written for exactly the command that then failed never
got its chance. Sorting content by load *guarantee* rather than content type
(credit: Conneely) means the index's guarantee has to be mechanical too.

So bootstrap installs `~/.claude/hooks/memory-loader.sh` **by default** and
registers it under both **SessionStart** (main sessions: startup / resume /
clear / compact) and **SubagentStart** (subagents inherit CLAUDE.md but *not*
SessionStart output; the script skips the lean, read-only Explore and Plan
agent types — a default you override in `~/.claude/hooks/memory-loader.conf`,
never by editing the managed script). It injects the `## Entries` section of
`~/.claude/memory/MEMORY.md` — one script, two registrations, empirically
verified to reach both main-session and subagent context (2026-07-07, CLI
2.1.204). `--no-loader` skips it, `--uninstall-loader` removes it cleanly;
see BOOTSTRAP.md.

What makes it a distinct category from every hook below:

- **It carries no facts.** It injects the index verbatim; the index stays the
  single source of truth, so the admission policy's duplication concerns
  don't arise.
- **It's infrastructure, not enforcement.** Removing it reverts the layer to
  instruction-based loading (the CLAUDE.md fallback line) — it doesn't make
  anything safer or less safe at an action point.
- **It is the one `settings.json` touch.** Bootstrap merges the two
  registration blocks with a real JSON parser, preserves every other key,
  event, and entry, refuses to touch an unparseable file, and removes exactly
  its own blocks on uninstall. Guardrail hooks remain hand-added.
- **It still gets a ledger row** (the one row bootstrap manages itself), with
  removal criteria like any other hook: gone the day the harness injects
  cross-project memory natively.

## When a guardrail hook is allowed (admission policy)

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
5. **No general mechanism would enforce it at the right moment** — with the
   memory-loader in place, the index line is already in context; if the
   failure was "the index never loaded," that's the loader's job, and it's
   fixed. A guardrail is justified only for the residual class: the line was
   in context and the agent still didn't dereference or apply it at the
   action point. For that class a broader loader is a placebo — enforcement
   has to sit on the tool call itself.
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
  | `Edit` / `Write` | `Edit\|Write` | `.file_path` (plus content) |
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
- **Settings-level `PreToolUse` hooks fire for subagent tool calls too**
  (probe-verified 2026-07-07): a guardrail registered in
  `~/.claude/settings.json` sees the same command issued inside a spawned
  subagent, payload tagged with an `agent_id`. So if a post-loader miss ever
  justifies a guardrail, it covers subagents at the action point as well.
  (SessionStart does *not* fire for subagents — SubagentStart is the
  subagent-side lifecycle event; the memory-loader uses both.)
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
