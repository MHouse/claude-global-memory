# claude-memory

**Global, cross-project memory for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) — the layer that survives across projects, complementing the built-in `/remember` (which is per-project). Just files plus install hygiene: no daemon, retrieval layer, auto-capture pipeline, or sync.**

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

The `<slug>` in the per-project path is harness-derived from the
working-directory path — each clone, worktree, and platform gets its
own. You don't compute it: the harness states the active directory at
session start, and to locate a sibling project's memory, list
`~/.claude/projects/` and match by basename.

**Cost note.** The cross-project layer loads its index (`MEMORY.md`)
into every session, in every project, by design. The real constraint
isn't raw token cost — it's *routing quality*: as the index grows,
the relevance signal weakens and Claude pulls in adjacent but
unrelated entries before raw size becomes the binding limit. Aim for
one line per entry in the index and keep the file under ~200 lines
(roughly 100 entries). A few high-value lines may run longer to carry
an inline imperative (see [File format](#file-format)) — reserve that
for the critical few, since each extra line spends the same
routing-quality budget. Past that, prune or promote — the
`/consolidate-memory` skill (see [Maintenance](#maintenance) below)
surfaces candidates; the `MEMORY.md.template` taxonomy documents an
explicit promotion path (when a memory matures, promote it to a skill
or plugin and shrink the entry to a short pointer).

## How this compares to related approaches

Several writers have published lightweight Claude Code memory patterns
this repo borrows from. A quick map of the landscape:

| | Storage | Load mechanism | Hooks | Frontmatter |
|---|---|---|---|---|
| [Pawel Huryn](https://substack.com/@huryn/note/c-216337711) | single `memory.md` | session-start instruction | — | — |
| [John Conneely](https://www.youngleaders.tech/p/how-i-finally-sorted-my-claude-code-memory) | dir + `memory.md` + `tools/` + `domain/` | session-start + `PreToolUse` hooks | yes (Python + shell wrapper, ~5ms / tool call) | — |
| **this repo** | dir + `MEMORY.md` + `tools/` + `domain/` | session-start instruction | — | `name` / `description` / `type` |
| [claude-mem](https://github.com/thedotmack/claude-mem) | SQLite + worker daemon | hooks + MCP queries | yes | n/a |

**vs Huryn's pattern** — same session-start instruction; adds directory
structure, type frontmatter, and a bootstrap so it's reproducible
across machines.

**vs Conneely's "Try it yourself" recipe** — same directory structure;
drops the `PreToolUse` hooks (no Python dependency, no `settings.json`
mutation, no per-tool-call latency), adds a `type` frontmatter so the
index can route without scanning every file, and explicitly positions
this as the cross-project layer alongside the built-in per-project
memory (which Conneely's recipe doesn't acknowledge).

**vs `claude-mem`** — a different scale of system entirely. Pick
`claude-mem` if you want auto-capture, semantic search, and a worker
process running locally. Pick this if you want control over what gets
saved, plain Markdown you can `cat` and audit, and a bootstrap that
doesn't outlive the day you ran it. The trade is auto-magic for
auditability.

The lighter approaches (Huryn, Conneely, this repo) share one thing:
Claude reads plain Markdown via its existing `Read` / `Edit` / `Write`
tools — no new tool surface, no daemon, no opaque store.

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
individual files, ordered however you find useful. The index loads into
every session; the entry files themselves load **lazily**, only when one
looks relevant to the task at hand. That makes the index line the only
part of an entry guaranteed to be in context at the moment you act — so
for the handful of gotchas that are both *frequent* and *costly* to get
wrong, lead the index line with the imperative rule itself rather than a
topic label, turning the always-loaded pointer into an always-on
reminder. `MEMORY.md.template` documents this convention (and when *not*
to reach for it) in full.

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

### Keeping in sync when this repo updates

Re-running the bootstrap is a safe drift check: it diffs the managed
regions in `~/.claude/memory/MEMORY.md` and `~/.claude/CLAUDE.md`
against the canonical content in this repo, and `--force` / `-Force`
resyncs them. Flag table, region boundaries, and the manual recipe
live in [BOOTSTRAP.md](BOOTSTRAP.md).

## Maintenance

Run the [`anthropic-skills:consolidate-memory`](https://docs.anthropic.com/en/docs/claude-code/slash-commands)
skill (also available as `/consolidate-memory`) periodically to merge
duplicates, prune stale facts, fix orphan links, and surface promotion
candidates. No-op on a small memory set — useful after ~10+ entries or a
few months of accumulation, whichever comes first.

## What this repo deliberately does *not* do

- **Run a daemon, worker, or MCP server.** Claude reads the files via
  its existing `Read` / `Edit` / `Write` tools. No new tool surface,
  no background process, no opaque store. If you want auto-capture
  or retrieval embeddings, pick a different tool.
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
