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
Nothing on disk is duplicated, nothing already there is overwritten —
including a hand-customised `~/.claude/CLAUDE.md` whose existing
sections stay exactly where they are.

After running, optionally seed `user_identity.md` and verify — both are
below and apply to either path. Done.

### Flags

| Flag (bash) | Flag (PowerShell) | Effect |
|---|---|---|
| (none) | (none) | Create anything missing — including the memory-loader hook; on regions already present, detect drift and report it without resyncing. Default. |
| `--force` | `-Force` | Rewrite drifted managed regions with the canonical content from this repo. Customisations *inside* the managed regions are lost. |
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
| `~/.claude/CLAUDE.md` | The `## Cross-project memory` section (its H2 through the next H2 or EOF) | Everything outside that section |
| `~/.claude/hooks/REGISTRY.md` | Everything above `## Registered hooks`, **plus** the single row whose first cell is `memory-loader` | All other rows below `## Registered hooks` |
| `~/.claude/hooks/memory-loader.sh` | The **whole file** (default-on; `.delivered` stamp) | Nothing inside it — but bootstrap won't write *through* a symlink/junction, won't overwrite an edited copy without `--force`, and an **unmodified**-but-stale copy auto-updates on a bare run (the stamp proves no user edit is at risk) |
| `~/.claude/settings.json` | The two `memory-loader` registration blocks under `hooks.SessionStart` / `hooks.SubagentStart` (identified by the command containing `/hooks/memory-loader.sh`) | **Everything else in the file** — other keys, other events, other entries in the same arrays. Merged with a real JSON parser, atomic replace; a file that doesn't parse is never touched (WARN + manual recipe instead) |
| `~/.claude/skills/<name>/SKILL.md` (each bundled skill) | The **whole file** (opt-in; present only after `--install-skills`) | Nothing inside it — but bootstrap won't write *through* a symlink/junction at that path, and won't overwrite a copy you edited without `--force` |

`REGISTRY.md` is the hooks ledger. Bootstrap seeds it and manages exactly one
row in it — the memory-loader's own. The loader is the only hook this scaffold
installs and its two registrations are the only `settings.json` writes; adding
any *other* hook is a documented, opt-in recipe in [`HOOKS.md`](HOOKS.md).

Each managed region carries an HTML comment marker so the ownership
boundary is visible in the file itself. Edit *outside* the managed
regions freely; treat *inside* them as upstream-owned. (Whole-file surfaces —
the loader script and each bundled skill — are the exception: no in-file
marker; a `.delivered` sidecar hash plays that role, letting bootstrap tell an
unmodified-but-stale copy from one you edited. And `settings.json` carries no
marker either — ownership there is by JSON shape, not by region.)

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
  skip list is a variable at the top of the script.

Behavior details, all covered by the test harness:

- An empty `## Entries` (fresh install) injects **nothing** — zero token cost
  until you save your first memory.
- Past ~200 entry lines the payload gains a leading WARNING line (and one on
  stderr) telling you to prune or promote — routing quality decays before
  token cost bites, and subagent fan-out multiplies both.
- Output is a single JSON `hookSpecificOutput.additionalContext` object;
  the harness validates it with a real JSON parser, quotes and backslashes
  included.
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

Without the hook, the layer degrades gracefully: the `CLAUDE.md` snippet
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
preservation) **and** the full per-skill matrix (run for each bundled skill:
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

### 3. Add the cross-project memory section to the global CLAUDE.md

Open (or create) the **global** `~/.claude/CLAUDE.md`. Append the
contents of [`snippets/cross-project-memory-claude-md.md`](snippets/cross-project-memory-claude-md.md)
verbatim — the file is the section itself, no commentary to strip.
It describes the injected index (how to dereference entries, where
saves go) and carries the fallback line for sessions where no injected
index is present.

If a "Cross-project memory" section already exists in your `CLAUDE.md`,
update its paths to match this machine instead of duplicating. (The
script does this check for you.)

> **Windows path note.** The harness reads `~/.claude/CLAUDE.md`
> correctly with the tilde, but if you need to reference these paths
> in a context that doesn't expand `~` (for example, a hook `command`
> string in `settings.json`), expand it manually:
> `C:\Users\<you>\.claude\memory\MEMORY.md`.

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
- `~/.claude/CLAUDE.md` contains the cross-project memory section
  pointing at the file above.
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

Once the memory set passes ~10 entries or a few months of accumulation
(no-op before that), run a consolidation pass periodically:

- **`memory-sweep`** (bundled here; `--install-skills`) — the whole-machine
  cross-store sweep: promotes cross-cutting per-project facts, and delegates the
  per-directory deep clean of the cross-project store to `consolidate-memory`.
- **`anthropic-skills:consolidate-memory`** — the deep single-directory pass
  that `memory-sweep` calls; on its own it does not span stores or promote.
