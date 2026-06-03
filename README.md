# claude-memory

**Global, cross-project memory for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) — the layer that survives across projects, complementing the built-in `/remember` (which is per-project). Just files plus install hygiene: no daemon, retrieval layer, auto-capture pipeline, or sync.**

Sets up a small Markdown store at `~/.claude/memory/` that every Claude
Code session reads at startup, so durable cross-project knowledge is
available everywhere you work, not just inside one repo. Claude Code
already loads *per-project* memory automatically; this fills the gap for
facts that aren't tied to a single repo — "here's my vault path", "this
tool has a gotcha I hit twice", "I format commits like X".

This repo ships the **scaffold**, not anyone's content. Bootstrap a fresh
empty system on any machine and let it accrue naturally.

## Relationship to built-in `/remember`

This **complements** the built-in system; it doesn't replace it. Both run
in parallel after bootstrap, covering different scopes:

|                   | Built-in `/remember`               | `claude-memory` (this repo)              |
|-------------------|------------------------------------|------------------------------------------|
| Scope             | Per-project                        | Global (cross-project)                   |
| Location          | `~/.claude/projects/<slug>/memory/`| `~/.claude/memory/`                      |
| Setup             | Zero — built into Claude Code      | One-time `./bootstrap.sh`                |
| Auto-capture      | Yes — model saves opportunistically| Yes — model saves opportunistically      |
| Loaded at         | Session start (per-project)        | Session start (every session)            |
| Good for          | "This Postgres table joins weirdly to that one in *this* repo" | "Don't suggest `cp -i` on Git Bash; use `\\cp`" |

Pick the layer when you save: a fact true only inside one project goes to
built-in `/remember`; a fact true everywhere on this machine goes under
`~/.claude/memory/`. Both share the same file format, so promoting one to
the other is a `mv` between dirs. (The per-project `<slug>` is
harness-derived — each clone, worktree, and platform gets its own; the
harness names the active directory at session start, so you never compute
it.)

**Cost note.** The index (`MEMORY.md`) loads into every session, in every
project, by design. The binding constraint isn't token cost — it's
*routing quality*: as the index grows, the relevance signal weakens and
Claude starts pulling in adjacent-but-unrelated entries. Keep entries to
one line and the file under ~200 lines (~100 entries); past that, prune
or promote (the [`/consolidate-memory`](#maintenance) skill surfaces
candidates). A few high-value lines may run longer to carry an inline
rule — see [File format](#file-format) — but that spends the same budget,
so reserve it for the critical few.

## How this compares

Several lightweight Claude Code memory patterns predate this one; it
borrows from them. Where it fits:

| | Storage | Load mechanism | Hooks | Frontmatter |
|---|---|---|---|---|
| [Pawel Huryn](https://substack.com/@huryn/note/c-216337711) | single `memory.md` | session-start instruction | — | — |
| [John Conneely](https://www.youngleaders.tech/p/how-i-finally-sorted-my-claude-code-memory) | dir + `memory.md` + `tools/` + `domain/` | session-start + `PreToolUse` hooks | yes (Python + shell wrapper, ~5ms / tool call) | — |
| **this repo** | dir + `MEMORY.md` + `tools/` + `domain/` | session-start instruction | — | `name` / `description` / `type` |
| [claude-mem](https://github.com/thedotmack/claude-mem) | SQLite + worker daemon | hooks + MCP queries | yes | n/a |

- **vs [Huryn](https://substack.com/@huryn/note/c-216337711)** — same
  session-start instruction, plus directory structure, `type` frontmatter,
  and a reproducible bootstrap.
- **vs [Conneely](https://www.youngleaders.tech/p/how-i-finally-sorted-my-claude-code-memory)**
  — same directory structure, but drops the `PreToolUse` hooks (no Python,
  no `settings.json` mutation, no per-call latency) and adds `type`
  frontmatter so the index routes without scanning every file.
- **vs [claude-mem](https://github.com/thedotmack/claude-mem)** — a
  different scale entirely: pick it for auto-capture, semantic search, and
  a local worker; pick this for plain Markdown you can `cat` and audit,
  with no background process. The trade is auto-magic for auditability.

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

The top-level `MEMORY.md` is the index — one-line links to the entry
files. The index loads every session, but entries load **lazily**, only
when one looks relevant to the task. So the index line is the only part
of an entry guaranteed to be in context when you act: for the few gotchas
that are both *frequent* and *costly*, lead that line with the imperative
rule itself, not a topic label — turning the always-loaded pointer into
an always-on reminder. `MEMORY.md.template` covers this (and when not to)
in full.

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

- **Run a daemon, worker, or MCP server.** Claude reads the files via its
  existing `Read` / `Edit` / `Write` tools — no new tool surface, no
  background process, no opaque store. Want auto-capture or retrieval
  embeddings? Pick a different tool.
- **Ship anyone's actual memories.** Memories are personal and
  machine-local; this repo only carries the scaffold.
- **Sync memories across machines.** Each install accrues its own entries.
  For shared content, use another mechanism (your dotfiles, a shared note)
  — not this repo.
- **Define a "right" memory taxonomy.** The four types are a starting
  point. The template hints at sub-organisation (`tools/{name}.md`,
  `domain/{topic}/`, `general.md`) but grow whatever fits your work.

## License

MIT — see [LICENSE](LICENSE).
