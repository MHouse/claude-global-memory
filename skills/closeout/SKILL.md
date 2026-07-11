---
name: closeout
description: Run a structured end-of-session pass over the memory and documentation systems that drift out of sync between sessions. Use when the user signals the end of substantive work — phrases like "we're done", "wrap up", "session closeout", "prune now", or after a PR merges. Also use when the user says "what have we learned" and is winding down. Each step checks its own prerequisites and skips cleanly when a system is not present (no project memory yet, no hooks registry, non-git project, no optional tooling), so it works equally well in a minimal install and a richly tooled one. Optional: ships with claude-global-memory but installs only when explicitly requested.
---

# Session Closeout

You are running the `closeout` workflow. The user has signaled that a meaningful unit of work is done and wants a structured pass over the memory and documentation systems that quietly drift out of sync between sessions.

This skill is **portable and tool-agnostic**. It assumes only plain Markdown memory files and git. Every richer system (an auto-captured learnings store, a doc-release skill, a memory-consolidation skill) is an **optional adapter**, gated by a presence check — when the tool is absent, the step skips in one line. Never assume any specific framework is installed.

## The systems this skill may touch

Each system is **conditional** — if the project does not use it, the step skips silently. Do not manufacture work for systems that are not present.

1. **Cross-project memory** at `~/.claude/memory/` — the machine-wide store. Present on any install that ran the claude-global-memory bootstrap; entries may not exist yet.
2. **Project memory** at `~/.claude/projects/<slug>/memory/` — per-project, built into Claude Code. May not exist for an uncurated project.
3. **Repo documentation** — `CLAUDE.md`, `README`, `ARCHITECTURE.md`, `CHANGELOG` (whichever exist).
4. **Hooks registry** at `~/.claude/hooks/REGISTRY.md` — only if present. Review only; **never install hooks.**
5. **Git hygiene** — the current session's branch only; never touch other sessions' state. Skip entirely if this is not a git repo.
6. **Optional tooling adapters** — an auto-captured learnings store, a documentation-release skill, or a memory-consolidation skill, *only if installed*. Each is gated; see Step 7.

## The action ledger

Work the steps below as **analysis** — they investigate each system and **record proposed actions to an in-memory ledger**. They do NOT prompt inline. All the picking happens once, at the end (Step 9). Each ledger entry carries:

- **label** — short imperative ("Save the X gotcha", "Delete merged branch").
- **group** — one of **Memory saves** · **Hygiene fixes** · **Git**.
- **destination** — REQUIRED for memory saves: name the exact home (cross-project memory / project memory / repo doc). One home per finding; never duplicate across systems.
- **recommendation** — `recommended` or `optional`.
- **payload** — what's needed to execute: the entry text + frontmatter for a save, the exact before→after for an edit, the command for a git op.
- **destructive** — `true` for deletes/removals.

Nothing executes until the user confirms in Step 9.

## The checklist

Run the steps in order. State the current state of each, record any warranted action to the ledger, and **do not prompt inline**. Skip a step in one line when it does not apply — do not manufacture work to look thorough.

### Step 1: Establish the session bound, then recap

Fix the scope first — this is where closeout most often goes wrong. "This session" is the current conversation, **including any compaction summary at the top of context**. Compaction is context *compression*, not a session boundary: earlier-this-session work that now survives only as a summary is IN scope. Never replay *other* sessions or walk deeper git history unless the user explicitly asks.

Determine the lower bound, most authoritative first:

1. **A prior closeout detectable in THIS session** — visible earlier in the conversation, or a marker (below) whose recorded `ppid` matches the current shell. Cover only work since that point.
2. **The marker** at `~/.claude/.closeout/<slug>.json` — scope the recap to `git log <marker.head>..HEAD`. Survives compaction and new sessions.
3. **This session's visible context** — when no marker exists.

```bash
SLUG=$(git rev-parse --show-toplevel 2>/dev/null | sed 's#^/##; s#[/: ]#-#g' | tr 'A-Z' 'a-z'); [ -z "$SLUG" ] && SLUG=unknown
M=~/.claude/.closeout/$SLUG.json
echo "PPID:$PPID  HEAD:$(git rev-parse --short HEAD 2>/dev/null)  branch:$(git branch --show-current 2>/dev/null)"
[ -f "$M" ] && echo "prior marker: $(cat "$M")" || echo "no prior closeout marker for $SLUG"
```

**Then recap.** Within that bound, identify what shipped — PRs, version bumps, key decisions — and state it back in a tight 2-3 sentence paragraph. If nothing substantive shipped, say so plainly; most of the rest of the checklist will not apply.

### Step 2: Lessons worth saving

Synthesize the genuine, durable lessons from the session — things that would save time next session. Filter aggressively; the most common mistake is over-saving.

- ❌ **Skip:** generic engineering wisdom ("test before shipping", "review catches bias") — principles, not facts about this user or environment.
- ❌ **Skip:** code-level details already in commits, CHANGELOG, or the repo's CLAUDE.md.
- ❌ **Skip:** anything already in the user's global CLAUDE.md or under
  `~/.claude/rules/` — re-saving a live promoted rule as a memory violates
  the move-not-copy contract (RULES.md in the claude-global-memory repo).
- ✅ **Save:** operational quirks of the user's environment (OS behavior, tool failure modes, version-drift gotchas).
- ✅ **Save:** explicit user preferences stated during the session.
- ✅ **Save:** project-specific operator details that don't fit the repo's own docs.

Record each surviving candidate as a **Memory save** and **name its destination explicitly**:

- **cross-project memory** (`~/.claude/memory/…`) — facts/preferences useful across ≥2 unrelated projects, or machine/tool gotchas. Machine-wide.
- **project memory** (`~/.claude/projects/<slug>/memory/…`) — this-repo operator context that doesn't fit the repo's own CLAUDE.md.
- **repo doc** (`CLAUDE.md` / `README` / …) — when the finding belongs in committed docs, not memory.

Before queuing, check whether an existing entry already covers it; if so, record "already covered — skip" rather than a duplicate. Tag each `recommended` or `optional`. Use the memory file format (frontmatter `name` / `description` / `type`; for `feedback` type, add `**Why:**` and `**How to apply:**` body lines). Do NOT write anything yet.

Only synthesize lessons from within the session bound set in Step 1. Do not re-surface candidates the user declined in a prior closeout — declining is final.

### Step 3: Cross-project memory hygiene

Scan `~/.claude/memory/MEMORY.md` and the entries it links (treat the Step 2 candidates as if already saved, so you catch a new entry that would duplicate or supersede an existing one). Concrete checks:

- **Broken links** — for each index line, verify the linked file exists. A link to a missing file is a hygiene fix.
- **Stale facts** — did anything this session make an existing entry wrong (a renamed tool, a moved path, a retired flag)?
- **Over-long entries** — flag index lines longer than one line (the index is a routing surface; long lines erode it). Reserve multi-line entries for the rare frequent-and-costly gotcha.
- **Duplicates** — obvious overlaps that should merge.
- **Index size** — if the index passes ~100 entries / ~200 lines, note it; routing quality degrades past that. Also check bytes: past ~9KB of `## Entries` the memory-loader's injection gets truncated by the harness to a ~2KB preview, so entries below the fold lose their always-in-context guarantee — note it, and note any imperative line sitting below the first ~2KB (the preview keeps the head).
- **Fold placement** — if `## Entries` contains a `<!-- fold -->` marker, flag above-fold entries that no longer earn always-resident status (untouched across recent sessions and not imperative rules) as below-the-fold demotion candidates; record them as Hygiene fixes. Closeout only flags — a fold move is applied solely through the Step 9 confirmation, and the marker itself is user territory. If there is no marker and the index is past ~9KB, note that `memory-sweep` proposes fold placement.

Spot-check based on what's salient from this session — not a full audit. This is a shallow spot-check, not deep consolidation — and closeout is single-project, so it can't see whether a fact is duplicated across *other* projects or has earned promotion. Defer deep work to the consolidation skills (Step 7): single-directory dedup to `consolidate-memory`; cross-store dedup + **promotion** of cross-cutting facts to `memory-sweep`. If neither is installed, say so. Record each fix to the ledger (group: **Hygiene fixes**) with the exact before→after in the payload.

### Step 4: Project memory hygiene

Same scan against `~/.claude/projects/<slug>/memory/MEMORY.md`, if it exists. The session's changes are most likely to invalidate things here, because project memory is most entangled with the code that just changed. Skip in one line if there is no project memory directory.

### Step 5: Repo documentation drift

Diff the session's changes against the repo's own docs (`CLAUDE.md`, `README`, `ARCHITECTURE.md`, `CHANGELOG` — whichever exist). Did the diff touch documented behavior, commands, flags, or file layout?

- If a **documentation-release skill is installed** (presence-check it), it is the canonical tool — don't run it inline; record a ledger action to run it.
- Otherwise, record a ledger action to scan the doc files for drift against the diff, with the before→after in the payload.
- If the docs were already updated inline as part of the work this session, say so and skip — no follow-up.

### Step 6: Hooks registry review

Only if `~/.claude/hooks/REGISTRY.md` exists. Review the registered rows for entries whose hook script or owning memory file no longer exists, or whose stated removal criterion is now met. Record any as **Hygiene fixes**. **Never install or modify hooks here** — this is a documentation review of the registry only.

### Step 7: Optional tooling adapters (only if installed)

These steps run *only* when the corresponding tool is present. Presence-check first; if absent, skip in one line — do not treat the absence as a finding.

- **Auto-captured learnings store** — if a learnings tool is on PATH, scan recent entries for content drift (a recommended workflow that changed even though files still exist), and record corrected entries. Skip in one line if no such tool is installed.
- **Deep memory consolidation** — these are deliberate passes, so **recommend (record a ledger action), never run them inline.** If `memory-sweep` (bundled alongside closeout) is installed and Step 3/4 found more than a couple stale entries, the cross-project index is growing, or a saved lesson looks like it may already live in other projects (a promotion candidate closeout can't verify), record an action to run `memory-sweep` — the whole-machine, cross-store + promotion pass. If only `anthropic-skills:consolidate-memory` is available, record that instead for single-directory dedup. If neither is installed, skip.

This is the only place framework-specific tooling appears, and every line here is gated. The four steps above (2-6) are the portable core and must produce useful output with none of these tools present.

### Step 8: Git hygiene (current session only)

Skip the whole step in one line if `git rev-parse --is-inside-work-tree` fails. Otherwise, three checks against the current session's branch:

- Is the branch merged into its base (locally: `git log <branch>..<base>` empty; or via the host's PR API if available)?
- Is the remote branch gone?
- Can the local branch be deleted from the main worktree?

If all clean, record the cleanup (group: **Git**; `destructive: true`): delete the merged remote branch, remove the worktree, delete the local branch. **Do not prune other sessions' worktrees or branches** — even if merged; list them at most as "deferred pending user confirmation".

### Step 9: Consolidated confirmation (the one prompt)

Everything Steps 2-8 recorded now goes to the user **once**. Group the ledger by `group` (**Memory saves** · **Hygiene fixes** · **Git**) and present it as a single batch the user can pick from — tick what to do, leave the rest. For each item show its label, its destination (for memory saves, named in full), and the before→after (for edits) or the command + consequence (for destructive git ops). State which items you recommend.

If the ledger is empty, skip this step and say so in Step 10.

When the user asks "am I right that X is stale?" or similar, lead with a direct yes/no, then the nuance. An unticked item is a complete decline — no pushback, no re-asking.

**Execute** exactly the picked actions, in order: memory writes → hygiene edits → git. Skip the rest.

### Step 10: Final summary + stamp the marker

Produce a tight "cycle wrap": what shipped; what memory/doc entries were added or updated and where; what's deferred (stale worktrees, pending doc updates, declined items); any open follow-ups the user mentioned. Then stamp the marker so the next run can bound from here — do this even if the ledger was empty (the recap still happened). Skip only outside a git repo.

```bash
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  mkdir -p ~/.claude/.closeout
  SLUG=$(git rev-parse --show-toplevel 2>/dev/null | sed 's#^/##; s#[/: ]#-#g' | tr 'A-Z' 'a-z'); [ -z "$SLUG" ] && SLUG=unknown
  printf '{"ts":"%s","head":"%s","branch":"%s","ppid":"%s"}\n' \
    "$(date -u +%FT%TZ 2>/dev/null)" "$(git rev-parse HEAD 2>/dev/null)" "$(git branch --show-current 2>/dev/null)" "$PPID" \
    > ~/.claude/.closeout/$SLUG.json
fi
```

**Checkpoint the cross-project store.** If `~/.claude/memory` is a git repo (`git -C ~/.claude/memory rev-parse --git-dir` succeeds) and `git -C ~/.claude/memory status --porcelain` shows pending changes, commit them all: `git -C ~/.claude/memory add -A`, then a one-line message naming the project and what changed (e.g. `closeout: claude-global-memory - 2 saves, 1 trim`). This checkpoints the whole session's saves — ad-hoc mid-session writes included, not just Step 9 picks — so whole-file index writes are recoverable and sweeps are diffable. Local history only: **never add a remote, never push** — the store stays machine-local. Skip in one line when the store is not a git repo.

Don't propose new work in the summary — this is closing out, not opening up.

## Important rules

- **The session bound (Step 1) governs scope.** Compaction is not a boundary — the compaction summary is this-session work, in scope. Never replay other sessions or deeper git history for lessons unless asked.
- **Gather, then confirm once.** Steps 2-8 record to the ledger and never prompt inline; Step 9 is the single confirmation. Nothing is written, edited, or deleted until the user picks it.
- **Don't duplicate across systems — and name the home.** One home per finding (repo doc vs cross-project memory vs project memory). If a finding is already covered, record "already covered — skip".
- **Optional tooling is always gated.** Never assume a specific framework is installed; presence-check and skip cleanly. The portable core (Steps 2-6, 8) stands on its own.
- **Never install or modify hooks.** Step 6 reviews the registry as documentation only.
- **Respect existing state.** Don't prune other sessions' worktrees. Don't overwrite a curated memory entry without showing the diff first.
- **Lead with a direct yes/no** when the user asks whether something is stale or whether they're right.
- **Don't propose new work in the closing.** The summary lands the plane.
