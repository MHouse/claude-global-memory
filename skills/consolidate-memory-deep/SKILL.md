---
name: consolidate-memory-deep
description: Periodic deep consolidation across ALL memory stores at once — every per-project memory dir plus the cross-project store — with cross-store promotion. Use for a deliberate, occasional sweep: "deep memory consolidation", "consolidate all my memory", "sweep memory across projects", "promote memories to cross-project", "memory spring cleaning". NOT a session wrap-up (that's closeout) and broader than a single-directory pass (that's the base consolidate-memory): this is the only pass that spans stores and proposes promotions. Read-mostly; auto-applies only mechanical fixes and batches the rest for one confirmation.
---

# Deep Memory Consolidation

You are running the `consolidate-memory-deep` workflow: a deliberate, periodic sweep over **every** memory store on this machine at once, plus the cross-store move that nothing else does — **promotion** of facts that have proven cross-cutting from a project up into the cross-project layer.

This is **not** `closeout` (that closes out the current session, in the current project, end-of-session) and it is **broader** than the base `consolidate-memory` skill (which works one directory at a time and never promotes). Run this occasionally — after a few months or when the stores have visibly accreted — not every session.

This skill is **portable and tool-agnostic**: it assumes only plain Markdown memory files and git. It reads and edits files with your normal tools; it runs no daemon and needs no framework.

## The two scopes

1. **Per-project memory** — `~/.claude/projects/<slug>/memory/`, one dir per project slug. The harness derives slugs from the working directory; **never construct a slug** — enumerate the dirs that exist. Several slugs can be the *same logical project* (a clone, a worktree, another platform) — collapse those before reasoning about "unrelated projects."
2. **Cross-project memory** — `~/.claude/memory/`, the machine-wide store loaded into every session.

**Promotion** is the operation that spans them: a fact first saved in a project, which turns out to be useful across projects, belongs in the cross-project store. Promotion is the reason this skill exists; the base consolidate-memory cannot see across directories.

## Format is inherited, not fixed

Your system prompt's auto-memory section defines the directory, file format, and memory types — **follow it as the current source of truth.** When normalizing frontmatter (a fix below), normalize to **whatever that section currently specifies**, not to a format you remember from a past run. Act only on entries that diverge from the current format; on a fresh, current store this is a no-op.

## The apply model (read this before editing anything)

Findings split into two tiers by blast radius:

- **Auto-apply, then report** — mechanical, contained, git-reversible fixes: within-a-store dedup of clear duplicates, broken-link repair, relative→absolute date fixes, and frontmatter normalization to the current format. Just do these and list what you did.
- **Confirm-once batch** — anything interpretive or high-blast-radius. Two kinds qualify:
  - **Promotions** — they write into the cross-project store, which loads into *every* future session; a wrong one pollutes routing everywhere.
  - **Per-project retirements you cannot verify** — you are sweeping projects you are *not* currently inside, so you can't see their code to confirm a fact is truly stale.

  Gather these to a ledger and present them **once** at the end. Nothing in this tier is written until the user picks it.

The split is the point: a bad within-store merge is local and easily reverted; a bad cross-project entry is loaded everywhere. Spend confirmation only where it buys safety.

## Safety rules

- **Never mutate another session's in-flight worktree memory.** A `~/.claude/projects/<slug>/memory/` whose slug is a live worktree of an active session is not yours to prune — list it as "deferred pending confirmation," don't edit it.
- **Don't auto-delete a per-project fact you can't verify** — it goes to the confirm batch, not auto-apply.
- **Gather, then confirm once** — the deep pass can touch many stores; present one batch, not a prompt per store.
- **Preserve git-recoverability** — every auto-applied edit is to a tracked file; make no change you couldn't undo from history.

## The checklist

### Step 1: Inventory

Enumerate the stores and take stock — read-only.

```bash
ls -d ~/.claude/memory 2>/dev/null
ls -d ~/.claude/projects/*/memory 2>/dev/null
```

For each store: read its `MEMORY.md` index, skim the linked entries, and note size (entries, index line count). Build a working map of `{store -> entries(name, description, type, file)}`. Flag stores whose slug looks like a live worktree (e.g. contains `worktrees`) for the deferred list.

### Step 2: Per-project hygiene (each per-project store)

For each per-project store, within that store only:

- **Dedup** clear duplicates (two entries stating the same fact) — *auto-apply* the merge, keeping the richer file.
- **Broken links** — index lines pointing at missing files; `[[name]]` links with no matching `name:`. *Auto-apply* repairs.
- **Date references** — "next week"/"by Friday" → absolute dates. *Auto-apply*.
- **Frontmatter** — normalize to the current harness format (see above). *Auto-apply* divergences.
- **Stale facts** — an entry that looks outdated. You're outside the project's repo and can't verify, so **record to the confirm batch as a proposed retirement** — do not auto-delete.

### Step 3: Cross-project hygiene (`~/.claude/memory/`)

Same mechanical fixes (dedup / links / dates / frontmatter) — *auto-apply*. Plus:

- **Index budget** — keep `MEMORY.md` under ~200 lines / ~25KB / ~100 entries; if over, note the worst offenders to prune or promote-to-skill.
- **Over-long index lines** — collapse detail that belongs in the entry file back into it.
- **Stale facts** — for the cross-project store you generally *can* reason about machine/tool facts; clear-cut retirements can auto-apply, anything uncertain goes to the batch.

### Step 4: Promotion analysis (cross-store)

First, **collapse slugs to logical projects**: group clones/worktrees/platforms of one repo (same repo basename) so you count distinct projects, not distinct checkouts. When unsure whether two slugs are the same project, show both and let the user judge.

Then tier candidates:

- **High confidence — propose:** the *same* fact independently saved in **≥2 unrelated logical projects**. It has been re-learned; that's the canonical signal to promote.
- **Low confidence — flag only:** a single-project entry whose subject is plainly tool/environment/preference-general rather than project-specific. Note it as "watch — promote when it recurs"; do not propose action (if you can't picture the second project, it's probably per-project).

**Promotion is generalize-and-merge, never a verbatim move.** A per-project entry was written with project-specific framing; relocating it as-is carries that context and produces a bad cross-project entry. For each high-confidence candidate, **draft a project-neutral entry** that merges the ≥2 sources, and record it to the confirm batch **showing the drafted text alongside the source entries** so the user can see what framing was stripped and merged. Flag it for review of residual project-specific wording. Never auto-apply a promotion.

**Demotion** (cross-project → a single project, rare): if a cross-project entry is really about one project, record a proposed demotion to the batch too.

### Step 5: Confirm once, then execute

Present the ledger as a single batch, grouped:

- **Auto-applied (already done)** — list mechanical fixes per store, for transparency.
- **Promotions** — for each: the drafted general entry, its proposed destination + index line + one-line "why it crossed over," and the source entries it merges/retires.
- **Per-project retirements (unverified)** — the entry and why it looks stale.
- **Demotions** — source + proposed destination.
- **Deferred** — worktree-session stores left untouched.

The user ticks what to apply. For each confirmed **promotion**: write the new cross-project entry, add its `MEMORY.md` index line (with the "why it crossed over" note), then retire the per-project originals and update their indices. For confirmed retirements/demotions: apply them. Leave unticked items alone — a decline is final.

### Step 6: Summary

Report: stores swept; mechanical fixes auto-applied (counts per store); promotions / retirements / demotions applied; index sizes before→after for stores that changed; and what was deferred. Don't open new work in the summary.

## Important rules

- **This is the periodic deep pass, not session closeout.** If the user is wrapping up a session, that's `closeout`. If they want one directory tidied, that's the base `consolidate-memory`. Use this when they want the whole machine swept and promotions surfaced.
- **Tiered apply governs everything**: mechanical fixes auto-apply; promotions and unverifiable retirements wait for the single confirmation.
- **Promotion rewrites, never copies** — and is always reviewed.
- **Never touch another session's worktree memory** without confirmation.
- **Normalize to the current harness format**, never a remembered snapshot.
