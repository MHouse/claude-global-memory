# claude-global-memory

**Global, cross-project memory for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) — the layer that survives across projects, complementing the built-in `/remember` (which is per-project). Just files, one small loader hook, and install hygiene: no daemon, retrieval layer, auto-capture pipeline, or sync.**

Sets up a small Markdown store at `~/.claude/memory/` whose index a
bootstrap-installed hook injects into every Claude Code session — and
into non-lean subagents — at startup, so durable cross-project knowledge
is mechanically present everywhere you work, not just inside one repo. ("Global" here
means every project on *this machine* — a local store, not a shared or
cloud-synced one.) Claude Code already loads *per-project* memory
automatically; this fills the gap for
facts that aren't tied to a single repo — "here's my vault path", "this
tool has a gotcha I hit twice", "I format commits like X".

This repo ships the **scaffold**, not anyone's content. Bootstrap a fresh
empty system on any machine and let it accrue naturally.

A memory store needs upkeep, not just setup — entries and docs drift out of
sync across sessions, and a store that quietly rots is worse than none. So the
package also ships **optional** maintenance skills,
[`closeout`](skills/closeout/SKILL.md) and
[`memory-sweep`](skills/memory-sweep/SKILL.md), installed
only on request (`--install-skills`). They assume only plain Markdown plus git and treat any
richer tooling as optional, so they keep the minimalism intact. The scaffold sets
the store up; the bundled skills keep it healthy — `closeout` at session end,
`memory-sweep` for periodic cross-store consolidation and promotion. See [Maintenance](#maintenance).

## Relationship to built-in `/remember`

This **complements** the built-in system; it doesn't replace it. Both run
in parallel after bootstrap, covering different scopes:

|                   | Built-in `/remember`               | `claude-global-memory` (this repo)              |
|-------------------|------------------------------------|------------------------------------------|
| Scope             | Per-project                        | Global (cross-project)                   |
| Location          | `~/.claude/projects/<slug>/memory/`| `~/.claude/memory/`                      |
| Setup             | Zero — built into Claude Code      | One-time `./bootstrap.sh`                |
| Opportunistic save| Yes — model saves opportunistically| Yes — model saves opportunistically      |
| Loaded at         | Session start (per-project, harness-injected) | Session + subagent start (hook-injected) |
| Good for          | "This Postgres table joins weirdly to that one in *this* repo" | "Don't suggest `cp -i` on Git Bash; use `\\cp`" |

Pick the layer when you save: a fact that only applies inside one project
goes to built-in `/remember`; a fact that applies everywhere on this machine goes under
`~/.claude/memory/`. Both share the same file format, so promoting one to
the other is a `mv` between dirs. (The per-project `<slug>` is
harness-derived — each clone, worktree, and platform gets its own; the
harness names the active directory at session start, so you never compute
it.)

**Cost note.** The index (`MEMORY.md`) is injected into every session, in
every project — and into every non-lean subagent, which multiplies the
spend under heavy fan-out — by design. Two constraints bound its size.
*Routing quality*: as the index grows, the relevance signal weakens and
Claude starts pulling in adjacent-but-unrelated entries — keep entries to
one line and the file under ~200 lines (~100 entries). *The injection
budget*: the harness truncates injected content past ~10k characters to a
~2KB preview, so only the head of an oversized index is guaranteed in
context — keep the `## Entries` payload under ~9KB and put imperative
lines first. The loader warns at both bounds, and
[`memory-sweep`](#maintenance) surfaces trims and promotion candidates
when it's time to prune. Past what pruning fixes, an optional
`<!-- fold -->` line splits the index into an ambient tier (injected
everywhere) and an on-demand tail — subagents get only the ambient
tier, and oversized main sessions degrade to it gracefully instead of
being truncated (see BOOTSTRAP.md, "The fold"). A few high-value lines may run longer to carry an inline
rule — see [File format](#file-format) — but that spends the same budget,
so reserve it for the critical few.

## How this compares

Several lightweight Claude Code memory patterns predate this one; it
borrows from them. Where it fits:

| | Storage | Load mechanism | Hooks | Frontmatter |
|---|---|---|---|---|
| [Pawel Huryn](https://substack.com/@huryn/note/c-216337711) | single `memory.md` | session-start instruction | — | — |
| [John Conneely](https://www.youngleaders.tech/p/how-i-finally-sorted-my-claude-code-memory) | dir + `memory.md` + `tools/` + `domain/` | session-start + `PreToolUse` hooks | yes (Python + shell wrapper, ~5ms / tool call) | — |
| **this repo** | dir + `MEMORY.md` + `tools/` + `domain/` | mechanical injection: `SessionStart` + `SubagentStart` hooks (default-on, opt-out) | memory-loader by default; guardrails opt-in (see [`HOOKS.md`](HOOKS.md)) | `name` / `description` / `type` |
| [claude-mem](https://github.com/thedotmack/claude-mem) | SQLite + worker daemon | hooks + MCP queries | yes | n/a |

- **vs [Huryn](https://substack.com/@huryn/note/c-216337711)** — Huryn's
  pattern loads via a session-start instruction; this repo used to as well,
  until a postmortem showed the instruction silently not firing is the
  dominant failure mode. It now injects mechanically via hooks, plus
  directory structure, `type` frontmatter, and a reproducible bootstrap.
- **vs [Conneely](https://www.youngleaders.tech/p/how-i-finally-sorted-my-claude-code-memory)**
  — same directory structure, and an honest debt: his optional Part 2 — the
  `PreToolUse` loader most readers skipped — was the load-bearing piece all
  along. His underlying principle, sort content by **load guarantee** rather
  than content type, is exactly what this repo's salience design violated
  until 2026-07: imperative index lines lived in a surface whose loading was
  promised, never guaranteed. This repo now ships the same capability rebuilt
  on purpose-built events: `SessionStart`/`SubagentStart` instead of
  `PreToolUse` with a parent-PID once-per-session flag and a bash+Python
  wrapper; the payload is the cross-project `## Entries` only (the harness
  already injects per-project memory natively, subagents included); and
  coverage starts at turn 1 — response-formation-time `feedback` memories
  included — not at the first tool call. It also adds `type` frontmatter so
  the index routes without scanning every file, and keeps guardrail hooks
  behind the admission policy in [`HOOKS.md`](HOOKS.md).
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
metadata:
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

**Authoring conventions are inherited, not restated.** Frontmatter, linking,
body structure, and date handling follow the per-project memory format the
Claude Code harness defines and ships into every session: `type` nested under
`metadata:`, `[[name]]` links target a memory's `name:` field,
`feedback`/`project` bodies follow with `Why:` / `How to apply:` lines, and
relative dates are written absolute. This scaffold deliberately does **not**
copy those rules into the always-loaded surfaces (`MEMORY.md` preamble, the
`CLAUDE.md` snippet) — duplicating them buys nothing at write-time (the harness
instructions are already in context) and a stale copy that drifts against the
harness is worse than none. It differs from the per-project format in exactly
one way, which a reader can't infer and so is worth stating:

- **Group by subject, not one-fact-per-file.** A `tools/{name}.md` file
  collects several related gotchas for that tool; per-project memory keeps one
  fact per file. Conversely, a file that has drifted into unrelated subjects
  should be split back into per-subject files — group related, split unrelated.

Keep `name:` short and slug-like so `[[name]]` link targets stay clean rather
than full sentences.

The top-level `MEMORY.md` is the index — one-line links to the entry
files. The loader hook injects the index into every session (and every
non-lean subagent), but entries load **lazily**, only when one looks
relevant to the task. So the index line is the only part
of an entry guaranteed to be in context when you act: for the few gotchas
that are both *frequent* and *costly*, lead that line with the imperative
rule itself, not a topic label — turning the always-loaded pointer into
an always-on reminder. `MEMORY.md.template` covers this (and when not to)
in full.

## Where memories go (taxonomy)

Two orthogonal classifications. They should agree; when they don't, the file
is probably in the wrong place. (`MEMORY.md.template` keeps the type
definitions and the boundary rule always in the agent's context; this section
is the fuller reference — the pairings table, smell combos, and the
provenance/durability nuances.)

- **Directory** answers *what subject area*:
  - `tools/{name}.md` — external systems, CLIs, vaults, services (Obsidian,
    gcloud, gh).
  - `domain/{topic}/` — knowledge about a product, codebase, or business area
    that spans sessions. A staging area: when it matures, promote it to a skill
    or plugin and shrink the memory to a short pointer.
  - `general.md` — cross-cutting writing/workflow preferences.
  - top level — identity and persistent preferences (they don't fit `tools/`
    or `domain/`).
- **Frontmatter `type`** answers *what kind of knowledge* (`user` / `feedback` /
  `project` / `reference`, defined above) and tells Claude *how to apply* it.

Typical pairings:

| Memory | File | `type` |
|---|---|---|
| "gh PR merge gotcha in a worktree" | `tools/gh.md` | `reference` |
| "Don't suggest `cp -i` on Git Bash" | `tools/git-bash.md` | `feedback` |
| "Default name + email for commits" | top-level `user_identity.md` | `user` |
| "Prefer no trailing summaries" | top-level `general.md` | `user` (declared) or `feedback` (corrected) |
| "Obsidian vault at `C:\Users\…`" | `tools/obsidian.md` | `reference` |

**Smell combos** — if you write one of these, the memory is probably misplaced:

- `tools/X.md` with `type: project` — the fact is about a *specific project's*
  use of tool X, not a cross-project gotcha. Move it to per-project memory
  (`~/.claude/projects/<slug>/memory/`).
- `domain/X/…` with `type: user` — user preferences aren't domain knowledge.
  Move to `general.md` or a dedicated user memory file.

**`feedback` vs `user` — provenance, not content.** `user` is a declarative fact
about the human ("default email is X"); `feedback` is a lesson from a past
interaction ("don't mock the DB in tests — we got burned"). Same content, typed
by whether the human stated it (`user`) or Claude learned it from a correction
(`feedback`).

**`project` vs `reference` — durability.** `reference` points at external systems
that outlive any project (vault paths, CLI quirks, dashboards); `project`
captures in-flight work context (the *why* of a rewrite, a deadline) and decays
quickly. Cross-project `project` memories are rare — usually that belongs in
per-project memory.

## Quick start

```bash
git clone https://github.com/MHouse/claude-global-memory.git
cd claude-global-memory
./bootstrap.sh        # macOS / Linux
# or
.\bootstrap.ps1       # Windows
```

The script is idempotent — it creates `~/.claude/memory/`, seeds an empty
`MEMORY.md` from the template, ensures `~/.claude/CLAUDE.md` exists,
appends the cross-project memory section if it isn't already there, and
installs the memory-loader hook (the injection mechanism; `--no-loader`
to skip, `--uninstall-loader` to remove — see
[BOOTSTRAP.md](BOOTSTRAP.md)). Re-running is a no-op once the system is
in place; existing customisations in `CLAUDE.md` and everything else in
`settings.json` are preserved.

### Keeping in sync when this repo updates

Re-running the bootstrap is a safe drift check: it diffs the managed
regions in `~/.claude/memory/MEMORY.md` and `~/.claude/CLAUDE.md`
against the canonical content in this repo, and `--force` / `-Force`
resyncs them. Flag table, region boundaries, and the manual recipe
live in [BOOTSTRAP.md](BOOTSTRAP.md).

## Maintenance

Three passes keep the store from rotting, at three cadences. The two bundled
skills install on demand with `./bootstrap.sh --install-skills` (or
`.\bootstrap.ps1 -InstallSkills`); pass skill names to install a subset, omit
for all. Re-sync on demand with `--force`; remove with `--uninstall-skills`.

- **`closeout` — session-end, bundled, opt-in.** A structured end-of-session
  sweep over the memory and documentation systems that drift between sessions:
  broken index links, stale or over-long entries, repo-doc drift, git hygiene.
  Runs when you signal "wrap up" / "session closeout". Scoped to the current
  session and project; needs only plain Markdown and git.
- **`memory-sweep` — periodic, bundled.** The occasional cross-store pass over
  **every** memory store at once — all per-project dirs plus the cross-project
  store. It is the only tool that proposes **promotions**: per-project facts
  that have proven cross-cutting, moved up to the cross-project layer. It does
  **not** reimplement the per-directory deep clean — it *delegates* that to
  `consolidate-memory` (run on the cross-project store), inheriting that skill's
  behavior as it evolves. Promotions are proposed, never auto-applied.
- **`/consolidate-memory` — single-directory, external.** The
  [`anthropic-skills:consolidate-memory`](https://docs.anthropic.com/en/docs/claude-code/slash-commands)
  skill is the deep per-*directory* consolidation engine: merge duplicates,
  prune stale facts, fix orphan links. `memory-sweep` calls it; it does not
  itself span stores or promote.

The division of labor by scope and cadence: `closeout` is the frequent, shallow,
*this-session/this-project* pass; `consolidate-memory` is the deep
*single-directory* engine; `memory-sweep` is the occasional *whole-machine*
sweep that runs `consolidate-memory` on the cross-project store and adds
cross-store **promotion**. `closeout` defers deep, cross-store work to
`memory-sweep` rather than duplicating it.

## What this repo deliberately does *not* do

- **Run a daemon, worker, or MCP server.** Claude reads the files via its
  existing `Read` / `Edit` / `Write` tools — no new tool surface, no
  background process, no opaque store. Want auto-capture or retrieval
  embeddings? Pick a different tool.
- **Install hooks beyond the loader, or touch `settings.json` for anything
  else.** Bootstrap installs exactly one hook — the memory-loader, the
  layer's load mechanism (default-on, opt-out, cleanly uninstallable) — and
  edits `settings.json` only for its two registration blocks, merged with a
  real JSON parser so everything else in the file is preserved. Beyond that:
  Markdown only — the memory store, the hooks *registry*, and (opt-in,
  `--install-skills`) the bundled maintenance skills. Guardrail hooks remain
  a documented, opt-in exception you add by hand following
  [`HOOKS.md`](HOOKS.md).
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
