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
    `## Registered hooks`; never touches the rows below.
  - Each managed region carries an HTML-comment marker as the ownership
    boundary. The canonical section content is
    `snippets/cross-project-memory-claude-md.md`, appended verbatim — if
    you change the snippet, the drift-detection paths in both scripts
    must still match it.
  - `~/.claude/skills/closeout/SKILL.md`: a **whole-file** managed surface
    (not a region-in-a-file), installed only with `--install-closeout` /
    `-InstallCloseout` (default off). Bootstrap owns the entire file; a
    `.delivered` stamp distinguishes an unmodified-but-stale copy from a
    user-edited one, re-sync is on demand (`--force` or re-install, never
    automatic), and bootstrap refuses to write through a symlink/junction at
    that path. `--uninstall-closeout` removes it.
- **Never install hooks or write `settings.json`.** This prohibition is
  absolute — the scaffold installs no hooks and never touches `settings.json`.
  Hooks are a documented, opt-in exception users add by hand, governed by the
  admission policy in `HOOKS.md` and logged in `~/.claude/hooks/REGISTRY.md`.
  Bootstrap writes only Markdown: the memory store, the empty hooks registry,
  and — only with the explicit opt-in `--install-closeout` flag — a copy of the
  bundled `closeout` skill file. It never installs a hook or mutates
  `settings.json` to do any of that.
- **Keep docs and scripts in sync.** README.md, BOOTSTRAP.md, HOOKS.md, the
  templates, and the bootstrap scripts describe one system. A behavior
  change in the scripts usually needs a doc change too.

## Conventions

- The index (`MEMORY.md`) is a routing surface, not storage: one-line
  entries, file kept under ~200 lines. Lead a line with the imperative
  rule itself only for the frequent-and-costly gotchas.
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
  (CI also runs both on every PR; they cover the managed surfaces + the closeout
  matrix and are kept in lockstep, same as the two bootstrap scripts).

## Deploy Configuration

This repo doesn't deploy. It's a clone-and-run scaffold — distribution is
`git clone` + `./bootstrap.sh` (or `.\bootstrap.ps1`) per machine, and the
release mechanism is a git tag + GitHub Release cut by hand from `main` after
PRs merge (first one: `v1.0.0`). There's no server, host, or health-check URL,
so `/land-and-deploy` has nothing to act on here — use the feature-branch +
squash-merge PR flow above, then tag a release when a milestone warrants it.
