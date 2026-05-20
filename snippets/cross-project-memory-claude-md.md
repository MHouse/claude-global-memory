## Cross-project memory

<!-- Section managed by the claude-memory bootstrap (re-run with -Force / --force to resync). -->

`~/.claude/memory/` is the cross-project counterpart to the per-project
auto-memory directory at `~/.claude/projects/<slug>/memory/`. The index
lives at `~/.claude/memory/MEMORY.md`; entries linked from it are short
Markdown files with `name` / `description` / `type` frontmatter where
`type ∈ user, feedback, project, reference`.

At session start, read `~/.claude/memory/MEMORY.md` and load any entries
that look relevant to the current task. Treat its contents as additive
to whatever project-scoped memory is loaded automatically.

A memory belongs in `~/.claude/memory/` only if (a) the same fact would
be useful in at least two unrelated projects on this machine, or (b)
the human explicitly asks to remember it globally. Everything else —
project-specific tooling quirks, in-flight work context, per-repo
conventions — belongs in the per-project memory directory or that
project's `CLAUDE.md`. When in doubt, default to per-project: promoting
later is cheaper than demoting.
