---
name: memory-sweep
description: Periodic cross-store memory pass: inventories every memory store at once (all per-project dirs + the cross-project store), proposes PROMOTIONS of facts that have proven cross-cutting, and reconciles the promoted-rules tier (~/.claude/rules/memory/, governed by RULES.md). Use whenever the user wants a deliberate, occasional sweep across projects — "memory sweep", "sweep memory across projects", "promote memories to cross-project", "promote a memory to a rule", "rules sweep", "memory spring cleaning". Boundaries: NOT for saving a single new fact (that's the built-in /remember); NOT for tidying one directory (that's consolidate-memory, which this delegates to); NOT session wrap-up (that's closeout). This is the only pass that spans stores and promotes between them; promotions are proposed, never auto-applied.
---

# Memory Sweep

You are running the `memory-sweep` workflow: a deliberate, periodic pass that spans **every** memory store on this machine and does what nothing else does — **promotion** across tiers: facts that have proven cross-cutting move from a project up into the cross-project store, and settled cross-project directives that clear RULES.md's bar move up into the always-on rules tier (with the reverse demotions when they stop earning their keep).

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

If a `<!-- fold -->` marker exists, also measure the above-fold segment — the always-resident cost (subagents get only this; main sessions too once the full index is past the budget):

```bash
awk '/^## Entries[[:space:]]*$/{f=1;next} f && /^[[:space:]]*<!-- fold -->[[:space:]]*$/{exit} f' ~/.claude/memory/MEMORY.md | wc -c
```

- **Past ~9,000 bytes** (the loader warns at the same bound): the default proposal is a **fold move** — demote long-tail entries below a standalone `<!-- fold -->` line inside `## Entries`, proposing the marker itself if absent (ambient rules + high-value routers above; everything else below). A fold move buys budget without deleting anything: the tail stays in the index file, one announced file-read away. Trims still apply — tighten verbose index lines back to routers, merge near-duplicates — but demotion below the fold beats deletion. Target an above-fold segment comfortably around ~4–6KB, not just barely under the bound.
- **Ordering:** the preview keeps the head, so promoted **imperative** lines (see the index's "Index-line salience") belong at the top of `## Entries`. If any imperative line sits below the first ~2KB, propose moving it up.
- **Graduation to a skill — the exception, never the default.** Two shapes earn it, and only these: an entry that is **runbook-shaped** (a multi-step procedure invoked by intent — "apply the branch-protection standard" — not knowledge needed ambiently), or a **real cluster** — **≥3 related entries** collapsing into one skill, where one description line genuinely replaces several index lines. If you can't name the third entry, it's not a cluster. Everything else that's merely task-retrievable stays in the store and gets demotion, because every skill costs an always-resident description line and probabilistic triggering — one-entry-one-skill just moves the index's bytes to a worse neighborhood. Propose a graduation with the draft skill name + description and the entries/index lines it would retire.
- **Rule promotion — the other exception, orthogonal to graduation.** A skill takes procedural knowledge on-demand; a rule takes a **settled, universal, flat directive** always-on (full text in every session and non-lean subagent). Candidates go through Step 2c's admission gate, not this one — note them here only to hand off.

Record proposals to the confirm batch (Step 5) — like promotions, never auto-applied.

### Step 2c: Rules-tier pass (promoted rules under `~/.claude/rules/memory/`)

The promoted-rules tier is governed by `RULES.md` in the claude-global-memory
repo — read it before proposing anything here; its admission policy and
rewrite recipe are the canon, this step is just the schedule. Bootstrap never
touches this tier; this pass is its only maintenance.

**Inventory + budget.** List `~/.claude/rules/memory/*.md` and read the
ledger at `~/.claude/memory/rules-ledger.md` (absent = empty tier). Measure
ambient bytes — the tier has **no mechanical warning anywhere**; this report
is the only meter:

```bash
cat ~/.claude/rules/memory/*.md 2>/dev/null | wc -c   # promoted tier
cat ~/.claude/rules/*.md ~/.claude/rules/**/*.md 2>/dev/null | wc -c  # whole ambient rules surface
```

Report both. A promoted tier past a handful of files or a few KB gets a
demotion review, not more promotions — every byte lands in every session
*and* every non-lean subagent, bypassing the fold.

**Reconcile, both directions.** A file under `rules/memory/` with no ledger
row: propose the row (or demotion, if it wouldn't clear admission today). A
row with no file: the user deleted the rule by hand — treat as a demotion
request, offer the reconstruction. Also flag any *other* stray `.md` under
`~/.claude/rules/` that isn't a rule (notes, drafts, `*-old.md`): everything
there loads into context forever; propose relocation.

**Demotion review.** Propose demoting a rule that: turned out conditional (a
project conflict was observed — automatic evidence), went stale or was
superseded by newer memories, or duplicates a live memory entry (move-not-copy
was violated; keep one). Demotion = reconstruct the memory from rule text +
the row's verbatim `Why`, file it in the store with an index line, delete the
rule file and the row.

**Promotion candidates.** From the *cross-project* store only, entries
clearing all four RULES.md admission bars (settled; universal on this
machine; doesn't compress to one line; index-line tier failed at least once
— you need the evidence, not a vibe). For each, **draft the rewrite** per
RULES.md's recipe (directive from `How to apply:` in imperative voice;
operative when/unless conditions hoisted out of the `Why:`; one-line
rationale kept iff it steers edge cases), then apply the stand-alone test:
the rule text alone must reproduce the memory's intended behavior on the
known edge cases. Fails at rule size → not a candidate; don't propose.
Record survivors to the confirm batch **showing the source memory beside the
drafted rule text** — the diff between them is exactly what the user reviews.

Never write drafts, scratch, or anything but confirmed rule files under
`~/.claude/rules/` — every `.md` there is ambient context from its first
session.

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
- **Injection-budget fold moves/trims/reorder** — proposed `<!-- fold -->` placement or cross-marker moves, line tightenings, and imperative-lines-first moves from Step 2b, with the measured byte counts (full and above-fold). Fold moves are proposals like everything else here — the marker is user territory, never moved without a tick.
- **Rules tier (Step 2c)** — the ambient byte report, reconciliation fixes, demotions (rule text + the memory it reconstructs), and promotions (source memory beside drafted rule text, plus the ledger row each would get).
- **Promotions** — each drafted general entry, its destination + index line + one-line "why it crossed over," and the source entries it merges/retires.
- **Demotions** — source + proposed destination.
- **Graduations** (rare — Step 2b's bar) — the drafted skill name + description, the entries it absorbs, and the index lines it retires. For a confirmed one: draft the SKILL.md, confirm its home with the user first (skill setups vary — plain `~/.claude/skills/` vs a managed skills repo), then retire the absorbed entries and their index lines.
- **Store versioning** (only when `~/.claude/memory` is **not** a git repo) — one optional proposal to initialize local history, so sweeps and closeouts can checkpoint the store from then on: `git -C ~/.claude/memory init -b main`, a `.gitignore` with `*.bak`, a `.gitattributes` with `* -text` (git must never rewrite store bytes — the injection budget is byte-measured), then an initial snapshot commit. Local history only: **never add a remote, never push** — the store stays machine-local. Omit the item entirely when the store is already a repo.
- **Recommendations** — other-project stores worth consolidating in-project.
- **Deferred** — worktree-session stores left untouched.

Present the batch in prose (each promotion's drafted entry beside its source entries — too long for picker labels), **state which you recommend** (high-confidence promotions, clear demotions) vs optional, then take the pick as one consolidated confirmation: tick what to apply, leave the rest; if there are more candidates than a single multi-select cleanly holds, group them **within that single prompt** (one round-trip — never sequential rounds) or take picks free-form. For each confirmed **promotion**: write the new cross-project entry, add its `MEMORY.md` index line, then retire the per-project originals and update their indices. Apply confirmed demotions. For a confirmed **rule promotion**: write the rule file under `~/.claude/rules/memory/`, add its ledger row (creating `~/.claude/memory/rules-ledger.md` from the skeleton in RULES.md if absent), then delete the source memory entry and its index line — move, never copy. A confirmed **rule demotion** runs the reverse. **An unticked item is a complete decline — no pushback, no re-asking.**

After executing, if `~/.claude/memory` is a git repo (`git -C ~/.claude/memory rev-parse --git-dir` succeeds), commit the applied batch: `git -C ~/.claude/memory add -A`, then a one-line message like `memory-sweep: 2 promotions, 3 trims` — one commit per sweep, so the pass is diffable and reversible. Local history only: **never add a remote, never push** — the store stays machine-local. Skip silently when the store is not a git repo — the Store-versioning item above was the one offer, and an unticked offer gets no follow-up (a confirmed init's snapshot commit already captures the applied batch).

### Step 6: Summary

Report: stores inventoried; what the delegated `consolidate-memory` pass changed; promotions/demotions applied; recommendations made; what was deferred. Don't open new work.

## Important rules

- **Delegate, don't reimplement.** The per-directory deep clean is `consolidate-memory`'s; this skill inherits it and owns only cross-store inventory + promotion (including the rules tier).
- **Promotion rewrites, never copies — and is always reviewed.** Never auto-apply one. This holds for rule promotions doubly: RULES.md's admission bar and stand-alone test gate them, and the source memory is retired the moment the rule lands.
- **Demotion is the default budget relief; graduation is the exception.** A skill is earned by the runbook-or-cluster test (Step 2b), never by byte pressure alone — one-entry-one-skill is explicitly rejected. A rule is earned by RULES.md's four-bar admission test (Step 2c), never by enthusiasm — the rules tier has no fold and no warnings, so restraint is the instrumentation.
- **Nothing lands under `~/.claude/rules/` except confirmed rule files.** No drafts, no scratch, no ledger — every `.md` there is always-on context. The ledger lives in the store.
- **Never mutate another session's worktree memory**, and never deep-clean another project's store remotely — recommend running the in-project tools instead.
- **This is the periodic cross-store sweep, not session closeout** (`closeout`) and not a single-directory pass (`consolidate-memory`).
