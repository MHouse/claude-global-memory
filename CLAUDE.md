# CLAUDE.md — claude-global-memory

Repo-specific guidance for working in this project. General/global
preferences live in `~/.claude/CLAUDE.md`; ongoing-work context lives in
this project's auto-memory index
(`~/.claude/projects/<slug>/memory/MEMORY.md`).

## What this repo is

The **public scaffold + bootstrap** for a cross-project Claude Code
memory layer at `~/.claude/memory/`. It ships the *structure* (templates,
bootstrap scripts, docs) — **never anyone's actual memories**.

- This repo (`MHouse/claude-global-memory`) is the **scaffold**. It is
  distinct from a separate, private contents repo that holds real memory
  entries and backup/restore tooling. Don't conflate them; features that
  belong to one rarely belong to the other.
- The memory store is **machine-local and not synced** by this repo.
  Anything you add here must preserve that boundary (see README's
  "What this repo deliberately does *not* do").

## Hard constraints

- **Never commit real memory content.** Examples and templates only.
  `## Entries` in any shipped `MEMORY.md`-like file stays empty/illustrative.
- **Bootstrap stays idempotent and non-destructive.** `bootstrap.sh` and
  `bootstrap.ps1` must produce the same result, be safe to re-run, and
  never overwrite user content outside the managed regions. Keep the two
  scripts in lockstep — a change to one needs the matching change to the
  other.
- **Respect the managed-region contract** (documented in BOOTSTRAP.md):
  - `~/.claude/memory/MEMORY.md`: bootstrap owns everything **above**
    `## Entries`; never touches `## Entries` and below.
  - `~/.claude/CLAUDE.md`: bootstrap owns only the `## Cross-project
    memory` H2 section; never touches anything outside it.
  - `~/.claude/hooks/REGISTRY.md`: bootstrap owns everything **above**
    `## Registered hooks`; never touches the rows below — except the single
    row whose first cell is `memory-loader`, which bootstrap itself adds on
    install and removes on `--uninstall-loader`.
  - `~/.claude/hooks/memory-loader.sh`: **whole-file** surface with a
    `.delivered` stamp, installed **by default** (`--no-loader` / `-NoLoader`
    skips this run). One deliberate divergence from skill semantics: an
    unmodified-but-stale copy auto-updates on a bare run (the stamp proves no
    user edit is lost); an edited copy still requires `--force`. Runtime
    config (the skip-list override) lives beside it in `memory-loader.conf` —
    pure user territory that bootstrap never writes, stamps, or removes, so
    configuring the loader never trips the stamp.
  - `~/.claude/settings.json`: bootstrap owns exactly the two memory-loader
    registration blocks under `hooks.SessionStart` / `hooks.SubagentStart`
    (identified by the command containing `/hooks/memory-loader.sh`).
    Everything else — keys, events, sibling entries — is preserved. The merge
    always goes through a real JSON parser (python in bootstrap.sh, native in
    bootstrap.ps1), never text-munging; writes are build→validate→atomic-
    rename; an unparseable file is never touched. `--uninstall-loader` /
    `-UninstallLoader` is sticky (drops a `.memory-loader.optout` sentinel
    honored by bare re-runs; `--install-loader` / `-InstallLoader` clears it).
  - Each managed region carries an HTML-comment marker as the ownership
    boundary. The canonical section content is
    `snippets/cross-project-memory-claude-md.md`, appended verbatim — if
    you change the snippet, the drift-detection paths in both scripts
    must still match it.
  - Bundled skills (`skills/<name>/SKILL.md` → `~/.claude/skills/<name>/`):
    **whole-file** managed surfaces (not regions-in-a-file), installed only
    with `--install-skills` / `-InstallSkills` (default off; names select a
    subset, omit for all). Driven by the `$bundled_skills` / `$bundledSkills`
    registry + the `manage_skill` / `Manage-Skill` routine. Bootstrap owns each
    entire file; a `.delivered` stamp distinguishes an unmodified-but-stale copy
    from a user-edited one, re-sync is on demand (`--force` or re-install, never
    automatic), and bootstrap refuses to write through a symlink/junction at
    that path. `--uninstall-skills` removes them. Add a skill by dropping
    `skills/<name>/SKILL.md` and listing `<name>` in the registry.
- **The memory-loader is the only hook bootstrap installs, and its two
  registrations are the only `settings.json` writes.** The loader is the
  cross-project layer's load mechanism (HOOKS.md, "The load-bearing
  exception") — default-on, opt-out, cleanly and stickily uninstallable per
  the settings.json bullet above. Nothing else may install a hook or touch
  `settings.json`: guardrail hooks remain a documented, user-added exception
  governed by the admission policy in `HOOKS.md` and logged in
  `~/.claude/hooks/REGISTRY.md`. Everything else bootstrap writes is
  Markdown: the memory store, the hooks registry, and — only with the
  explicit opt-in `--install-skills` flag — copies of the bundled skill
  files.
- **Keep docs and scripts in sync.** README.md, BOOTSTRAP.md, HOOKS.md, the
  templates, and the bootstrap scripts describe one system. A behavior
  change in the scripts usually needs a doc change too.

## Conventions

- The index (`MEMORY.md`) is a routing surface, not storage: one-line
  entries, file kept under ~200 lines and its `## Entries` under ~9KB
  (the harness truncates bigger injections to a ~2KB preview). Lead a
  line with the imperative rule itself only for the frequent-and-costly
  gotchas, and keep those lines at the top — the preview keeps the head.
  An optional standalone `<!-- fold -->` line in `## Entries` (user
  territory — bootstrap never touches it) splits ambient from on-demand:
  subagents are injected with only what sits above it, and main sessions
  auto-degrade to the same once the full index exceeds the ~9KB budget.
- Four memory types only: `user`, `feedback`, `project`, `reference`.
  Don't invent new ones in shipped examples.
- Prose voice in docs is terse and opinionated; match it. Don't add
  features, abstractions, or tooling that wasn't asked for.

## Workflow

- Feature branch + squash-merge PR via `gh`. **Never push to `main`.**
- PR title = eventual squash subject; body uses `## What` / `## Why` /
  `## Verification`.
- "Testing" here is mostly running the bootstrap scripts against a
  throwaway `HOME`/`$env:USERPROFILE` and confirming idempotency + drift
  detection, since there's no app to run. The bundled harness automates
  exactly that — run **both** `bash test/verify.sh` and
  `pwsh -NoProfile -File test/verify.ps1` before landing a bootstrap change
  (CI also runs both on every PR; they cover the managed surfaces, the
  memory-loader contract, + the per-skill matrix and are kept in lockstep,
  same as the two bootstrap scripts).

## Deploy Configuration

This repo doesn't deploy. It's a clone-and-run scaffold — distribution is
`git clone` + `./bootstrap.sh` (or `.\bootstrap.ps1`) per machine, and the
release mechanism is a git tag + GitHub Release cut by hand from `main` after
PRs merge (first one: `v1.0.0`). There's no server, host, or health-check URL,
so `/land-and-deploy` has nothing to act on here — use the feature-branch +
squash-merge PR flow above, then tag a release when a milestone warrants it.
