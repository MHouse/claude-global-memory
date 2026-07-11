# Bootstrap the cross-project memory layer

Run once per machine. There's a script for the impatient and a manual
recipe for the curious — they produce the same result.

> Memories don't sync across machines. This repo ships only the scaffold —
> existing entries on another machine stay there; this machine's
> `~/.claude/memory/` starts empty and fills as you work.

## Quick path (recommended)

From your clone of this repo:

```bash
# macOS / Linux
./bootstrap.sh
```

```powershell
# Windows
.\bootstrap.ps1
```

The script does steps 1–3 below, seeds the hooks registry, and installs
the [memory-loader hook](#the-memory-loader-hook) (default on;
`--no-loader` skips it), then prints a summary of what changed.
It's **idempotent**: re-running is a no-op once the system is in place.
Nothing on disk is duplicated, nothing already there is overwritten.
Bootstrap does not write to `~/.claude/CLAUDE.md` — with one one-time
exception: earlier versions managed the rule's content as a
`## Cross-project memory` section *inside* that file, and bootstrap now
removes that leftover section (see
[the migration note](#one-time-migration-the-old-claudemd-section)).

After running, optionally seed `user_identity.md` and verify — both are
below and apply to either path. Done.

### Flags

| Flag (bash) | Flag (PowerShell) | Effect |
|---|---|---|
| (none) | (none) | Create anything missing — including the memory-loader hook; on regions already present, detect drift and report it without resyncing. Default. |
| `--force` | `-Force` | Rewrite drifted managed regions with the canonical content from this repo. Customisations *inside* the managed regions are lost. Also removes an *edited* superseded `CLAUDE.md` section during the one-time migration, and reinstalls a rule file you deleted. |
| `--dry-run` | `-WhatIf` | Report intended actions, write nothing. Combines with `--force`. |
| `--no-loader` | `-NoLoader` | Skip memory-loader management for this run only (no install, no drift check). |
| `--uninstall-loader` | `-UninstallLoader` | Remove the memory-loader: its `settings.json` registrations, the script + stamp, and its registry row. **Sticky** — an opt-out sentinel keeps later bare re-runs from reinstalling it. |
| `--install-loader` | `-InstallLoader` | Clear the opt-out sentinel and install the loader again. |
| `--install-skills [names]` | `-InstallSkills [-Skills <names>]` | Install bundled skills (`closeout`, `memory-sweep`) to `~/.claude/skills/` (default: not installed). Names select a subset; omit for all. Re-run, or `--force`, to re-sync an unmodified-but-stale copy. |
| `--uninstall-skills [names]` | `-UninstallSkills [-Skills <names>]` | Remove installed bundled skills (subset by name, or all). |

### What "drift" means

After the first bootstrap, the script's managed regions live inside two
files. If a later update to this repo changes their canonical content,
re-running the bootstrap will detect that your live files have drifted
from the new canonical and offer to resync.

| File | Managed region | Never touched |
|---|---|---|
| `~/.claude/memory/MEMORY.md` | Everything above `## Entries` | `## Entries` and everything below |
| `~/.claude/rules/cross-project-memory.md` | The **whole file** (default-on; `.delivered` stamp) | Nothing inside it — but bootstrap won't write *through* a symlink/junction, won't overwrite an edited copy without `--force`, and an **unmodified**-but-stale copy auto-updates on a bare run. Deleting the file while its stamp remains is the opt-out gesture: bare re-runs respect the deletion; `--force` (or deleting the stamp too) reinstalls |
| `~/.claude/hooks/REGISTRY.md` | Everything above `## Registered hooks`, **plus** the single row whose first cell is `memory-loader` | All other rows below `## Registered hooks` |
| `~/.claude/hooks/memory-loader.sh` | The **whole file** (default-on; `.delivered` stamp) | Nothing inside it — but bootstrap won't write *through* a symlink/junction, won't overwrite an edited copy without `--force`, and an **unmodified**-but-stale copy auto-updates on a bare run (the stamp proves no user edit is at risk). Its optional `memory-loader.conf` sibling is pure user territory: bootstrap never writes or removes it |
| `~/.claude/settings.json` | The two `memory-loader` registration blocks under `hooks.SessionStart` / `hooks.SubagentStart` (identified by the command containing `/hooks/memory-loader.sh`) | **Everything else in the file** — other keys, other events, other entries in the same arrays. Merged with a real JSON parser, atomic replace; a file that doesn't parse is never touched (WARN + manual recipe instead) |
| `~/.claude/skills/<name>/SKILL.md` (each bundled skill) | The **whole file** (opt-in; present only after `--install-skills`) | Nothing inside it — but bootstrap won't write *through* a symlink/junction at that path, and won't overwrite a copy you edited without `--force` |

`REGISTRY.md` is the hooks ledger. Bootstrap seeds it and manages exactly one
row in it — the memory-loader's own. The loader is the only hook this scaffold
installs and its two registrations are the only `settings.json` writes; adding
any *other* hook is a documented, opt-in recipe in [`HOOKS.md`](HOOKS.md).

Each managed region carries an HTML comment marker so the ownership
boundary is visible in the file itself. Edit *outside* the managed
regions freely; treat *inside* them as upstream-owned. (Whole-file surfaces —
the loader script, the cross-project rule, and each bundled skill — work by
`.delivered` sidecar hash instead: it lets bootstrap tell an
unmodified-but-stale copy from one you edited. And `settings.json` carries no
marker either — ownership there is by JSON shape, not by region.)

#### One-time migration: the old CLAUDE.md section

Earlier versions of this bootstrap managed the rule's content as a
`## Cross-project memory` section inside `~/.claude/CLAUDE.md`. It now ships
as the rule file above — loaded into every session by Claude Code's
`~/.claude/rules/` mechanism (Claude Code ≥ 2.0.64) — so a leftover section
would be loaded twice. On every run, bootstrap looks for that section and:

- removes it silently when it carries the bootstrap ownership marker and
  matches the last shipped version
  ([`snippets/cross-project-memory-claude-md.md`](snippets/cross-project-memory-claude-md.md),
  kept **byte-frozen** for exactly this comparison — the live content is
  [`rules/cross-project-memory.md`](rules/cross-project-memory.md));
- reports a diff and waits for `--force` when the marker is there but the
  content differs (an older bootstrap's version, or your edits);
- never touches a section that lacks the marker — that one is yours.

Once the section is gone this is a permanent no-op, and nothing writes to
`~/.claude/CLAUDE.md` again.

### The memory-loader hook

The one hook this scaffold installs, and the reason the cross-project layer
doesn't depend on Claude *remembering* to read the index. It injects the
`## Entries` section of `~/.claude/memory/MEMORY.md` into context
mechanically, registered under two events:

- **`SessionStart`** — main sessions: startup, resume, `/clear`, and
  post-compaction, so the index survives every context rebuild.
- **`SubagentStart`** — spawned subagents, which inherit the global
  `CLAUDE.md` but *not* SessionStart output. The script skips the lean agent
  types (`Explore`, `Plan`): they deliberately load no CLAUDE.md to stay
  token-lean, are read-only, and multiply injection cost under fan-out. The
  default skip list is a variable at the top of the script — but override it
  in `memory-loader.conf` (below), never by editing the script: an edit marks
  the whole-file surface user-modified and blocks auto-update.

Behavior details, all covered by the test harness:

- An empty `## Entries` (fresh install) injects **nothing** — zero token cost
  until you save your first memory.
- The payload gains a leading WARNING line (and one on stderr) when the index
  outgrows its budget. Bytes bite first: the harness truncates injected
  context past **~10k characters** to a **~2KB preview** persisted to a file
  (probe-measured on CLI 2.1.204), so entries below the fold lose the
  in-context guarantee — the loader warns at ~9KB of entries. The ~200-line
  routing-quality cap is the second bound. Either way: trim or promote, and
  keep imperative lines at the top — the preview keeps the head.
- Output is a single JSON `hookSpecificOutput.additionalContext` object;
  the harness validates it with a real JSON parser, quotes and backslashes
  included.
- The payload ends with an `INDEX-END (N lines, N bytes)` sentinel. The
  truncation threshold is undocumented harness behavior and can move with any
  CLI update, so the system detects truncation rather than only predicting
  it: the cross-project rule's fallback treats an index block with no final
  `INDEX-END` line as truncated, reads the file instead, and tells the user.
  When that alarm fires, re-measure the threshold with
  `bash test/probe-truncation.sh` (manual and token-spending — it starts a
  few headless sessions against synthetic indexes; deliberately not part of
  `verify.sh`/CI) and re-calibrate `max_entry_bytes` plus the doc mentions
  the lockstep greps in the harness list.
- **The fold** (optional): a standalone `<!-- fold -->` line inside
  `## Entries` splits the index into an ambient above-fold segment and an
  on-demand tail. With a marker present, **SubagentStart** injections carry
  the above-fold segment only and the sentinel gains a pointer —
  `INDEX-END (N lines, N bytes; M lines below the fold -- read
  ~/.claude/memory/MEMORY.md)` — same stable prefix. Main sessions get the
  full index (the marker line itself is stripped) while it fits the ~9KB
  byte budget; past that they **auto-degrade** to the above-fold segment —
  a deliberate partial injection with the pointer sentinel, instead of a
  silent harness truncation. Grammar is strict: the
  marker is a whole line (surrounding whitespace and CRLF tolerated); marker
  text inside an entry line is data; the first marker wins and extras are
  reported on stderr; a marker with an empty tail withholds nothing. In fold
  mode the byte warning measures the **above-fold segment** and names it.
  The marker lives in user territory — bootstrap never writes, moves, or
  removes it.
- Optional config at `~/.claude/hooks/memory-loader.conf`, one supported key:
  `skip_agent_types="Explore Plan SomeNewLeanType"` — the value **replaces**
  the default (use a placeholder like `none` to skip no types). The conf is
  parsed, not sourced: a broken file is ignored (defaults apply, injection
  never dies) and Windows CRLF is tolerated. It is user territory — bootstrap
  never writes, stamps, or removes it, uninstall included — so configuring
  the loader keeps the script pristine and auto-update flowing.
- The registration command is `bash "<absolute path to the script>"` with a
  10-second timeout. On Windows that's Git Bash — already a Claude Code
  prerequisite; note that PowerShell's bare `bash` resolves to the WSL stub,
  which is why the harness locates Git Bash explicitly.
- `bootstrap.sh` needs `python3`/`python` for the `settings.json` merge (a
  real JSON parser; the file is never text-munged). Without one it WARNs and
  prints the manual block below. `bootstrap.ps1` uses PowerShell's native
  JSON handling — no dependency.

Uninstall with `--uninstall-loader` / `-UninstallLoader`: removes the two
registration blocks (other hooks untouched; an event key emptied by the
removal is dropped), deletes the script and stamp, removes the registry row,
and drops `~/.claude/hooks/.memory-loader.optout` so later bare re-runs stay
out. `--install-loader` / `-InstallLoader` clears the sentinel and
reinstalls.

**Manual registration** (hook-less merge fallback, or if you skipped the
script): copy `hooks/memory-loader.sh` to `~/.claude/hooks/`, then merge this
into `~/.claude/settings.json` (append to the arrays if the events already
exist), substituting the absolute path:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "bash \"/home/you/.claude/hooks/memory-loader.sh\"", "timeout": 10 } ] }
    ],
    "SubagentStart": [
      { "hooks": [ { "type": "command", "command": "bash \"/home/you/.claude/hooks/memory-loader.sh\"", "timeout": 10 } ] }
    ]
  }
}
```

On Windows use the forward-slash form:
`bash "C:/Users/<you>/.claude/hooks/memory-loader.sh"`. Then add the
`memory-loader` row to `~/.claude/hooks/REGISTRY.md` (bootstrap prints and
manages the canonical row text).

Without the hook, the layer degrades gracefully: the cross-project rule
carries one fallback line telling Claude to read the index when no injected
copy is present in context — instruction-based loading, exactly what the
loader exists to replace, but better than nothing on a machine you can't
install into.

### Verifying a bootstrap change (the test harness)

There's no app to run, so verification means exercising `bootstrap` against a
throwaway `HOME` / `$env:USERPROFILE`. CI runs the bundled harness on every pull
request — `verify.sh` on Linux, `verify.ps1` on Windows — and you can run it locally:

```bash
bash test/verify.sh                      # macOS / Linux / Git Bash
pwsh -NoProfile -File test/verify.ps1    # Windows
```

Each spins up a throwaway home, runs `bootstrap` in every mode, asserts the
managed-surface contract (idempotency, drift detection, `--force` resync, entry
preservation), the cross-project rule surface + `CLAUDE.md` migration,
**and** the full per-skill matrix (run for each bundled skill:
`closeout` and `memory-sweep`), and exits non-zero on any
failure. CI runs both on every PR; run them locally before pushing too, since
it's faster — `bootstrap.sh` and `bootstrap.ps1` must behave identically, and the
two harnesses are kept in lockstep to prove it. The per-skill steps below are the
same checks spelled out by hand.

### Verifying a bundled skill by hand (optional; run on BOTH scripts)

Each bundled skill is opt-in and a *whole-file* managed surface, so verify it
separately against a throwaway `HOME` / `$env:USERPROFILE`. The walkthrough uses
`closeout`; the same steps apply to any bundled skill — swap the name. Run the
recipe with `bootstrap.sh` **and** `bootstrap.ps1` — they must behave identically.

1. **Bare run, not installed** → summary shows `skip … closeout skill (not installed)`.
2. **`--install-skills closeout`** → `created … (closeout installed)`; `SKILL.md` and a
   `.delivered` stamp now exist under `~/.claude/skills/closeout/`.
3. **Bare run again** → `exists … (in sync)`, nothing written.
4. **Edit the installed `SKILL.md`, bare run** → `DRIFT … (differs and looks
   edited)`; nothing written.
5. **`--force`** → `synced … (overwrote modified copy)`.
6. **Stale-but-unmodified copy** (older content whose normalized hash matches the
   stamp), bare run → `DRIFT … (newer version available; your copy is
   unmodified)`; `--install-skills closeout` or `--force` → `synced … (updated to
   current version)`.
7. **`--uninstall-skills closeout`** → `removed …`; the file is gone.
8. **Symlink/junction at `~/.claude/skills/closeout`**, `--install-skills closeout` →
   `WARN … is a symlink/junction; not managing it` (bootstrap never writes
   through it).

A bare run on a `HOME` where closeout was never installed must match today's
behavior exactly — installing closeout is strictly opt-in.

### PowerShell execution policy

If running `.\bootstrap.ps1` errors out with "running scripts is
disabled," either invoke once with bypass:

```powershell
pwsh -ExecutionPolicy Bypass -File .\bootstrap.ps1
```

…or flip the user-scope policy once:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

## Manual recipe (if you'd rather see each step)

### 1. Create the memory directory

```bash
# macOS / Linux
mkdir -p ~/.claude/memory
```

```powershell
# Windows
New-Item -ItemType Directory -Force `
  -Path "$env:USERPROFILE\.claude\memory" | Out-Null
```

### 2. Seed `MEMORY.md` from the template

Copy [`MEMORY.md.template`](MEMORY.md.template) into the new directory
as `MEMORY.md`. Don't add entries yet — leave the **Entries** heading
empty.

```bash
cp MEMORY.md.template ~/.claude/memory/MEMORY.md
```

```powershell
Copy-Item MEMORY.md.template "$env:USERPROFILE\.claude\memory\MEMORY.md"
```

### 3. Install the cross-project memory rule

Copy [`rules/cross-project-memory.md`](rules/cross-project-memory.md) to
`~/.claude/rules/cross-project-memory.md` — Claude Code loads every `.md`
file under `~/.claude/rules/` into all sessions on this machine (rules
directories shipped in CLI **2.0.64**; on an older CLI, add the line
`@~/.claude/rules/cross-project-memory.md` to your `~/.claude/CLAUDE.md`
instead — the `@`-import inlines the same file). The rule describes the
injected index (how to dereference entries, where saves go) and carries the
fallback line for sessions where no injected index is present.

```bash
mkdir -p ~/.claude/rules
cp rules/cross-project-memory.md ~/.claude/rules/
```

```powershell
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.claude\rules" | Out-Null
Copy-Item rules\cross-project-memory.md "$env:USERPROFILE\.claude\rules\"
```

If your `~/.claude/CLAUDE.md` still has the `## Cross-project memory`
section an older bootstrap added, delete that section — the rule file
replaces it, and keeping both loads the content twice. (The script does
this migration for you.)

> **Windows path note.** The harness reads `~/.claude/rules/` and
> `~/.claude/CLAUDE.md` correctly with the tilde, but if you need to
> reference these paths in a context that doesn't expand `~` (for
> example, a hook `command` string in `settings.json`), expand it
> manually: `C:\Users\<you>\.claude\memory\MEMORY.md`.

### 4. Install the memory-loader hook

The load mechanism itself — without it the layer falls back to the
snippet's instruction-based fallback line. Follow the **manual
registration** block in [The memory-loader hook](#the-memory-loader-hook)
above: copy the script, merge the two registrations into
`~/.claude/settings.json`, add the registry row.

## Optionally seed `user_identity.md` (after either path)

Skip unless you want to. If you'd rather have your name/email
pre-loaded into every session, create one entry:

```markdown
---
name: User identity and email addresses
description: Which email to use in which context, and the default when ambiguous
metadata:
  type: user
---

- **Work email:** `<you@work.example>` — <context, e.g. employer; used for most things>
- **Personal email:** `<you@personal.example>` — <context, e.g. personal projects>

When uncertain which to assume in a new context, default to the work email and ask if the project looks personal.
```

Save as `~/.claude/memory/user_identity.md` and add a line to
`~/.claude/memory/MEMORY.md` under **Entries** linking to it. That's
the only seed worth doing during bootstrap; everything else accrues
naturally.

## Verify (after either path)

- `~/.claude/memory/MEMORY.md` exists with the taxonomy header and an
  empty `## Entries` section.
- `~/.claude/rules/cross-project-memory.md` exists (with its `.delivered`
  stamp beside it), and `~/.claude/CLAUDE.md` no longer contains a
  bootstrap-owned `## Cross-project memory` section.
- `~/.claude/hooks/memory-loader.sh` exists and `~/.claude/settings.json`
  contains its two registrations (one under `SessionStart`, one under
  `SubagentStart`), unless you opted out.
- Memory-load verification exercises itself naturally once entries
  accrue — an empty index injects nothing by design, so there's nothing
  to see yet. After the first entry lands, a fresh session should show a
  "Cross-project memory index" block in context (and a non-lean subagent
  should see it too); that's the smoke test.

That's it. Save memories as you work — by hand, or by asking Claude to
save them — and the system fills itself.

## Maintenance (later, not now)

If a session ever reports that the injected index lost its `INDEX-END`
sentinel (the cross-project rule tells Claude to say so), the harness's
truncation threshold has likely moved with a CLI update — re-measure it
with `bash test/probe-truncation.sh` and re-calibrate the loader's
`max_entry_bytes` and the docs it's lockstepped with.

Once the memory set passes ~10 entries or a few months of accumulation
(no-op before that), run a consolidation pass periodically:

- **`memory-sweep`** (bundled here; `--install-skills`) — the whole-machine
  cross-store sweep: promotes cross-cutting per-project facts, and delegates the
  per-directory deep clean of the cross-project store to `consolidate-memory`.
- **`anthropic-skills:consolidate-memory`** — the deep single-directory pass
  that `memory-sweep` calls; on its own it does not span stores or promote.
