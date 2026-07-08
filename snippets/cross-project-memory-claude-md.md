## Cross-project memory

<!-- Section managed by the claude-global-memory bootstrap (re-run with -Force / --force to resync). -->

`~/.claude/memory/` is the cross-project counterpart to the per-project
auto-memory directory at `~/.claude/projects/<slug>/memory/`. The
harness states the active per-project directory verbatim at session
start; each working directory (clone, worktree, platform) gets its own
slug, so finding a *sibling* project's memory directory is a matter of
listing `~/.claude/projects/` and matching by basename — don't try to
construct the slug from a path.

The index lives at `~/.claude/memory/MEMORY.md`; entries linked from it
are short Markdown files with `name` / `description` / `type`
frontmatter where `type ∈ user, feedback, project, reference`.

A "Cross-project memory index" block in context is that file's
`## Entries` section, injected mechanically by the memory-loader hook —
into main sessions (startup/resume/clear/compact) and non-lean
subagents alike, the same load guarantee the per-project layer gets.
Index lines are pointers: read the linked entry file under
`~/.claude/memory/` before acting on one. Fallback: if no such block is
present in context — or the block lacks its final `INDEX-END` line,
meaning the injection was truncated — read `~/.claude/memory/MEMORY.md`
before proceeding. This cross-project layer coexists with the per-project
auto-memory — separate scope, same file format and `type` frontmatter;
the same fact doesn't live in both layers, and the save threshold below
routes between them.

A memory belongs in `~/.claude/memory/` only if (a) the same fact would
be useful in at least two unrelated projects on this machine, or (b)
the human explicitly asks to remember it globally. Everything else —
project-specific tooling quirks, in-flight work context, per-repo
conventions — belongs in the per-project memory directory or that
project's `CLAUDE.md`. When in doubt, default to per-project: promoting
later is cheaper than demoting.
