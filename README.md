# claude-memory

**Global, cross-project memory for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) — the layer that survives across projects, complementing the built-in `/remember` (which is per-project).**

Sets up a small Markdown memory store at `~/.claude/memory/` that future
Claude Code sessions read at session start — so durable knowledge
(preferences, tool gotchas, vault paths, cross-project conventions) is
available everywhere you work, not just inside one repo.

This repo ships the **scaffold**, not anyone's content. Bootstrap a fresh
empty system on any machine and let it accrue naturally.

## Why this exists

Claude Code has built-in mechanisms for in-conversation context, and the
harness can load per-project memory automatically — but there is no built-in
home for *cross-project* durable knowledge ("here's my vault path", "this
tool has a subtle gotcha I hit twice", "I prefer commits formatted like
X"). This repo defines a simple convention for that layer and a five-minute
bootstrap to set it up.

## Relationship to built-in `/remember`

This **complements** the built-in memory system; it does not replace it.
Both run in parallel after bootstrap, covering different scopes:

|                   | Built-in `/remember`               | `claude-memory` (this repo)              |
|-------------------|------------------------------------|------------------------------------------|
| Scope             | Per-project                        | Global (cross-project)                   |
| Location          | `~/.claude/projects/<slug>/memory/`| `~/.claude/memory/`                      |
| Setup             | Zero — built into Claude Code      | One-time `./bootstrap.sh`                |
| Auto-capture      | Yes — model saves opportunistically| Yes — model saves opportunistically      |
| Loaded at         | Session start (per-project)        | Session start (every session)            |
| Good for          | "This Postgres table joins weirdly to that one in *this* repo" | "Don't suggest `cp -i` on Git Bash; use `\\cp`" |

Pick the right layer when saving: if the fact is true only inside one
project, let built-in `/remember` capture it. If it's true on this
machine everywhere, save it under `~/.claude/memory/`. Both use the same
file format and frontmatter conventions, so promoting a per-project
memory to cross-project is a `mv` between dirs.

The `<slug>` in the per-project path is derived from the working-directory
path; you don't pick it.

**Cost note.** The cross-project layer loads its index (`MEMORY.md`)
into every session, in every project, by design. At ~10–20 entries this
is a negligible token cost; at ~100+ it becomes meaningful. The
`/consolidate-memory` skill (see [Maintenance](#maintenance) below)
keeps the set bounded; the `MEMORY.md.template` taxonomy documents an
explicit promotion path — when a memory matures, promote it to a skill
or plugin and shrink the entry to a short pointer — which keeps the
actively-loaded set small.

## File format

Each memory is a short Markdown file with YAML frontmatter:

```yaml
---
name: Short title shown in the index
description: One-line summary of when and why this matters
type: user | feedback | project | reference
---

Body content — what to remember, when to apply it, paths or links if useful.
Keep it concise; this gets read into context every relevant session.
```

The four types:

- **`user`** — identity, persistent personal preferences (email aliases,
  default account when ambiguous, etc.).
- **`feedback`** — "next time, do X instead of Y" lessons captured from
  prior sessions; behavior corrections.
- **`project`** — durable facts about a specific product or codebase
  (planned features, TODOs that aren't yet scoped, owner notes).
- **`reference`** — pointers to external systems Claude should know about
  (vault paths, runbooks, tool quirks, CLI argument gotchas).

The top-level `MEMORY.md` is the index — a list of one-line links to the
individual files, ordered however you find useful.

## Quick start

```bash
git clone https://github.com/MHouse/claude-memory.git
cd claude-memory
./bootstrap.sh        # macOS / Linux
# or
.\bootstrap.ps1       # Windows
```

The script is idempotent — it creates `~/.claude/memory/`, seeds an empty
`MEMORY.md` from the template, ensures `~/.claude/CLAUDE.md` exists, and
appends the cross-project memory section if it isn't already there.
Re-running is a no-op once the system is in place; existing customisations
in `CLAUDE.md` are preserved.

For the manual recipe, see [BOOTSTRAP.md](BOOTSTRAP.md).

## Maintenance

Run the [`anthropic-skills:consolidate-memory`](https://docs.anthropic.com/en/docs/claude-code/slash-commands)
skill (also available as `/consolidate-memory`) periodically to merge
duplicates, prune stale facts, fix orphan links, and surface promotion
candidates. No-op on a small memory set — useful after ~10+ entries or a
few months of accumulation, whichever comes first.

## What this repo deliberately does *not* do

- **Ship anyone's actual memories.** Memories are personal and
  machine-local; this repo only carries the scaffold.
- **Sync memories across machines.** Each install accrues its own
  entries. If you want shared content, save it via another mechanism
  (your dotfiles, a shared note, etc.) — not this repo.
- **Define a "right" memory taxonomy.** The four types above are a
  starting point. The template hints at sub-organisation
  (`tools/{name}.md`, `domain/{topic}/`, `general.md`) but you're
  encouraged to grow whatever taxonomy fits your work.

## License

MIT — see [LICENSE](LICENSE).
