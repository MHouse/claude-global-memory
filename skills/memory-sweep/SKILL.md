---
name: memory-sweep
description: Periodic cross-store memory pass: inventories every memory store at once (all per-project dirs + the cross-project store) and proposes PROMOTIONS of facts that have proven cross-cutting. Use whenever the user wants a deliberate, occasional sweep across projects — "memory sweep", "sweep memory across projects", "promote memories to cross-project", "memory spring cleaning". Boundaries: NOT for saving a single new fact (that's the built-in /remember); NOT for tidying one directory (that's consolidate-memory, which this delegates to); NOT session wrap-up (that's closeout). This is the only pass that spans stores and promotes between them; promotions are proposed, never auto-applied.
---

# Memory Sweep

You are running the `memory-sweep` workflow: a deliberate, periodic pass that spans **every** memory store on this machine and does the one thing nothing else does — **promotion** of facts that have proven cross-cutting from a project up into the cross-project store.

It is **not** `closeout` (that closes out the current session, in the current project) and it is **not a reimplementation** of `anthropic-skills:consolidate-memory`. Per-directory deep cleaning (dedup, prune, link/date/format fixes) is *that* skill's job; this one **delegates** to it and adds only what it structurally can't do: seeing across stores and promoting between them. Run this occasionally — after a few months or when stores have visibly accreted — not every session.

Portable and tool-agnostic: plain Markdown + git, no daemon.

## Why delegate instead of reimplement

`consolidate-memory` is the canonical per-directory consolidation pass, and it evolves over time. Re-specifying its hygiene logic here would fork it — the copy drifts as the real skill improves. So this skill **never describes how to dedup/prune/normalize**; it invokes `consolidate-memory` for that and inherits whatever it currently does. What lives here is the cross-store orchestration and the promotion logic — neither of which `consolidate-memory` can do, because it works one directory at a time anchored to the current session's project.

That anchoring is also why this skill does **not** deep-clean other projects' stores remotely: `consolidate-memory` is meant to run *inside* a project. For stores other than the current project and the cross-project store, this skill only **reads** them (to find promotion candidates) and **recommends** running `consolidate-memory`/`closeout` in that project.

## The checklist

### Step 1: Inventory (read-only)

Enumerate the stores and take stock.

```bash
ls -d ~/.claude/memory 2>/dev/null
ls -d ~/.claude/projects/*/memory 2>/dev/null
```

For each store: read its `MEMORY.md` index, skim the linked entries, note size. Build a map of `{store -> entries(name, description, type, file)}`. Flag any store whose slug is a live worktree (e.g. contains `worktrees`) — never touch another session's in-flight memory; list it as deferred.

### Step 2: Deep-clean the cross-project store — by delegation

Run `consolidate-memory` against the **cross-project** store (`~/.claude/memory/`): invoke the `anthropic-skills:consolidate-memory` skill and have it operate on that directory. **Do not re-specify its steps** — whatever it does (merge duplicates, prune stale facts, fix orphan links, normalize to the current format) is the deep pass, and it improves as that skill does.

If `consolidate-memory` isn't available, say so and fall back to a *minimal* in-place tidy only — repair broken index links and obvious duplicates — explicitly **not** a deep reimplementation. Note the degradation in the summary.

### Step 2b: Injection-budget check (cross-project store only)

Loader-specific knowledge `consolidate-memory` doesn't have: the cross-project index's `## Entries` section is injected into context mechanically by the memory-loader hook, and the harness keeps only a **~2KB preview** of injections past **~10k characters** — entries below the fold lose the always-in-context guarantee. After the delegated clean, measure:

```bash
awk '/^## Entries[[:space:]]*$/{f=1;next} f' ~/.claude/memory/MEMORY.md | wc -c
```

- **Past ~9,000 bytes** (the loader warns at the same bound): propose trims — tighten verbose index lines back to routers (the linked entry body holds the detail), merge near-duplicate entries, demote low-value ones. Target comfortably under the bound, not just barely.
- **Ordering:** the preview keeps the head, so promoted **imperative** lines (see the index's "Index-line salience") belong at the top of `## Entries`. If any imperative line sits below the first ~2KB, propose moving it up.

Record proposals to the confirm batch (Step 5) — like promotions, never auto-applied.

### Step 3: Promotion analysis (cross-store — this skill's core)

First, **collapse slugs to logical projects**: group clones/worktrees/platforms of one repo (same repo basename) so you count distinct projects, not distinct checkouts. When unsure two slugs are the same project, show both and let the user judge.

Then tier candidates:

- **High confidence — propose:** the *same* fact independently saved in **≥2 unrelated logical projects**. It has been re-learned; that's the canonical signal to promote.
- **Low confidence — flag only:** a single-project entry whose subject is plainly tool/environment/preference-general. Note it as "watch — promote when it recurs"; don't propose action (if you can't picture the second project, it's probably per-project).

**Promotion is generalize-and-merge, never a verbatim move.** A per-project entry carries project-specific framing; relocating it as-is produces a bad cross-project entry. For each high-confidence candidate, **draft a project-neutral entry** merging the ≥2 sources, and record it to the confirm batch **showing the drafted text alongside the source entries** so the user can see what framing was stripped. Flag it for review of residual project-specific wording. **Never auto-apply a promotion.**

Demotion (a cross-project entry that's really about one project) is rare — record it to the batch too.

### Step 4: Other per-project stores — read, don't reach in

For per-project stores other than the current project's: you are outside their repo and can't verify staleness, and `consolidate-memory` is meant to run *inside* them. So **read them only** for promotion candidates (Step 3). If one looks like it needs a deep clean, **record a recommendation** to run `consolidate-memory`/`closeout` in that project — do not edit it from here.

### Step 5: Confirm once, then execute

Present one batch, grouped:

- **Delegated (already done)** — what `consolidate-memory` reported for the cross-project store.
- **Injection-budget trims/reorder** — proposed line tightenings and imperative-lines-first moves from Step 2b, with the measured byte count.
- **Promotions** — each drafted general entry, its destination + index line + one-line "why it crossed over," and the source entries it merges/retires.
- **Demotions** — source + proposed destination.
- **Recommendations** — other-project stores worth consolidating in-project.
- **Deferred** — worktree-session stores left untouched.

Present the batch in prose (each promotion's drafted entry beside its source entries — too long for picker labels), **state which you recommend** (high-confidence promotions, clear demotions) vs optional, then take the pick as one consolidated confirmation: tick what to apply, leave the rest; if there are more candidates than a single multi-select cleanly holds, group them **within that single prompt** (one round-trip — never sequential rounds) or take picks free-form. For each confirmed **promotion**: write the new cross-project entry, add its `MEMORY.md` index line, then retire the per-project originals and update their indices. Apply confirmed demotions. **An unticked item is a complete decline — no pushback, no re-asking.**

After executing, if `~/.claude/memory` is a git repo (`git -C ~/.claude/memory rev-parse --git-dir` succeeds), commit the applied batch: `git -C ~/.claude/memory add -A`, then a one-line message like `memory-sweep: 2 promotions, 3 trims` — one commit per sweep, so the pass is diffable and reversible. Local history only: **never add a remote, never push** — the store stays machine-local. Skip silently when the store is not a git repo.

### Step 6: Summary

Report: stores inventoried; what the delegated `consolidate-memory` pass changed; promotions/demotions applied; recommendations made; what was deferred. Don't open new work.

## Important rules

- **Delegate, don't reimplement.** The per-directory deep clean is `consolidate-memory`'s; this skill inherits it and owns only cross-store inventory + promotion.
- **Promotion rewrites, never copies — and is always reviewed.** Never auto-apply one.
- **Never mutate another session's worktree memory**, and never deep-clean another project's store remotely — recommend running the in-project tools instead.
- **This is the periodic cross-store sweep, not session closeout** (`closeout`) and not a single-directory pass (`consolidate-memory`).
