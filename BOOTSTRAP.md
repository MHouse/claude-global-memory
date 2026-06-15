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

The script does steps 1–3 below (and seeds the empty hooks registry — see
the drift table) and prints a summary of what changed.
It's **idempotent**: re-running is a no-op once the system is in place.
Nothing on disk is duplicated, nothing already there is overwritten —
including a hand-customised `~/.claude/CLAUDE.md` whose existing
sections stay exactly where they are.

After running, optionally seed `user_identity.md` (step 4) and verify
(step 5). Done.

### Flags

| Flag (bash) | Flag (PowerShell) | Effect |
|---|---|---|
| (none) | (none) | Detect drift and print a diff, but write nothing. Default. |
| `--force` | `-Force` | Rewrite drifted managed regions with the canonical content from this repo. Customisations *inside* the managed regions are lost. |
| `--dry-run` | `-WhatIf` | Report intended actions, write nothing. Combines with `--force`. |

### What "drift" means

After the first bootstrap, the script's managed regions live inside two
files. If a later update to this repo changes their canonical content,
re-running the bootstrap will detect that your live files have drifted
from the new canonical and offer to resync.

| File | Managed region | Never touched |
|---|---|---|
| `~/.claude/memory/MEMORY.md` | Everything above `## Entries` | `## Entries` and everything below |
| `~/.claude/CLAUDE.md` | The `## Cross-project memory` section (its H2 through the next H2 or EOF) | Everything outside that section |
| `~/.claude/hooks/REGISTRY.md` | Everything above `## Registered hooks` | `## Registered hooks` and the rows below |

`REGISTRY.md` is an empty hooks ledger. Bootstrap seeds it because it's plain
Markdown — it is **not** a hook and does **not** touch `settings.json`. The
scaffold installs no hooks; adding one is a documented, opt-in recipe in
[`HOOKS.md`](HOOKS.md).

Each managed region carries an HTML comment marker so the ownership
boundary is visible in the file itself. Edit *outside* the managed
regions freely; treat *inside* them as upstream-owned.

### PowerShell execution policy

If running `.\bootstrap.ps1` errors out with "running scripts is
disabled," either invoke once with bypass:

```powershell
powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1
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

### 3. Tell Claude Code to read the index at session start

Open (or create) the **global** `~/.claude/CLAUDE.md`. Append the
contents of [`snippets/cross-project-memory-claude-md.md`](snippets/cross-project-memory-claude-md.md)
verbatim — the file is the section itself, no commentary to strip.
That's what tells future Claude Code sessions to load the index at
session start.

If a "Cross-project memory" section already exists in your `CLAUDE.md`,
update its paths to match this machine instead of duplicating. (The
script does this check for you.)

> **Windows path note.** The harness reads `~/.claude/CLAUDE.md`
> correctly with the tilde, but if you need to reference these paths
> in a context that doesn't expand `~` (for example, a hook `command`
> string in `settings.json`), expand it manually:
> `C:\Users\<you>\.claude\memory\MEMORY.md`.

## 4. Optionally seed `user_identity.md`

Skip unless you want to. If you'd rather have your name/email
pre-loaded into every session, create one entry:

```markdown
---
name: User identity and email addresses
description: Default name + email for git config, commit trailers, etc.
type: user
---

- Name: <Your Name>
- Default email: <you@example.com>
- Other addresses (when ambiguous, default to the one above):
  - work: <you@work.example.com>
  - personal: <you@personal.example>
```

Save as `~/.claude/memory/user_identity.md` and add a line to
`~/.claude/memory/MEMORY.md` under **Entries** linking to it. That's
the only seed worth doing during bootstrap; everything else accrues
naturally.

## 5. Verify

- `~/.claude/memory/MEMORY.md` exists with the taxonomy header and an
  empty `## Entries` section.
- `~/.claude/CLAUDE.md` contains the cross-project memory section
  pointing at the file above.
- Memory-load verification exercises itself naturally once entries
  accrue — the index is intentionally empty at this point, so there's
  nothing to recall yet. The first real session that saves a memory
  and reads it back later is the smoke test.

That's it. Save memories as you work — by hand, or by asking Claude to
save them — and the system fills itself.

## Maintenance (later, not now)

Run the `anthropic-skills:consolidate-memory` skill periodically once
the memory set passes ~10 entries or a few months of accumulation,
whichever comes first. No-op before that.
