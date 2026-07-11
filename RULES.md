# Rules: the always-on tier, and when a memory earns it

**Claude Code loads every `.md` file under `~/.claude/rules/` — recursively —
into every session and every non-lean subagent, full text, no dereference
step.** (Harness-native since CLI 2.0.64; the same load path as the global
`CLAUDE.md`. The built-in lean agents, Explore and Plan, skip rules exactly
as they skip CLAUDE.md and the memory-loader — no surface reaches them. And
like CLAUDE.md, rules are snapshotted at session start and inherited by
subagents: an edit lands in new sessions, not in-flight ones.) That makes
the rules directory the strongest salience tier on
the machine, and also the least supervised: no fold, no loader warnings, no
budget instrumentation. This file governs how a memory gets promoted into
that tier, and how it gets demoted back out.

Two kinds of rules live under `~/.claude/rules/`, with different owners:

- **Scaffold-shipped** — today just `cross-project-memory.md`, installed and
  stamp-managed by the bootstrap (see BOOTSTRAP.md). Not this file's subject.
- **Promoted** — memories elevated to always-on. These are **user content,
  machine-local**, and live under `~/.claude/rules/memory/`. Bootstrap never
  writes, stamps, or removes anything there; `memory-sweep` proposes changes
  and a human applies them. This file is their admission policy.

## Where a rule sits on the salience ladder

1. **Entry body** — lazy; read when the index line looks relevant.
2. **Index line** — ambient pointer, injected by the memory-loader.
3. **Imperative index line, above the fold** — the rule compressed to one
   always-resident line. The default escalation; see the index template's
   "Index-line salience".
4. **Promoted rule** — the full directive, always resident, everywhere.
5. **Guardrail hook** — enforcement at the tool call (HOOKS.md; its own
   admission policy).

Rung 4 exists because rungs 3 and 5 leave a gap: an imperative line carries
only one line of nuance, and a `PreToolUse` guardrail can't fire on anything
that happens while *composing a response* — no tool call, no hook. For
response-formation behavior (tone, pushback, formatting-in-prose), rung 4 is
the ceiling of what's mechanically possible.

## The trade you are making

A promoted rule reaches every session **and every non-lean subagent, in
full — it bypasses the fold entirely**. The fold was engineered to keep
subagent injections lean; rules don't participate. And unlike the index,
nothing warns when this tier grows: the loader meters `## Entries`, but the
rules directory is silent. A typical promotion swaps a ~150-byte index line
for a 300–800-byte rule — a 4–7× ambient-cost increase for that fact,
multiplied under subagent fan-out.

So: keep the promoted tier to a **handful of files, a few KB total**. The
only meter is the `memory-sweep` rules pass — treat its byte report the way
you treat the loader's index warnings. And never park a non-rule `.md`
anywhere under `~/.claude/rules/` (notes, drafts, backups named `*-old.md`,
a README): everything there loads, forever, silently.

## Admission policy

Promote a memory to a rule only when **all four** hold — otherwise sharpen
the index line instead:

1. **Settled** — the lesson is stable, not still being calibrated. A rule
   states its content flatly and can't carry "we're still feeling this out."
2. **Universal on this machine** — applies in every project. A rule loads
   before project rules and is obeyed without judgment; a 95%-universal rule
   misfires in the other 5%. Project-conditional guidance belongs in that
   project's `CLAUDE.md` or per-project memory.
3. **Doesn't compress to one line** — if an imperative index line carries
   100% of the operative content, promotion buys nothing and costs plenty.
4. **The index-line tier failed at least once** — the line was in context
   and the behavior still missed. For tool-shaped destructive misses, check
   HOOKS.md first; for response-formation misses, this is the only
   escalation there is.

**No promotion without the failure evidence** — same discipline as hooks.
Every promoted rule gets a ledger row.

## The promotion rewrite (never a verbatim move)

A memory is a lesson with provenance, read after routing and weighed with
judgment. A rule is a standing instruction, read with zero conversational
context and obeyed. Copying a memory file into the rules directory fails on
genre — so promotion is a structured rewrite:

1. **The directive is the memory's `How to apply:` section**, rewritten in
   imperative voice. That section already is the operative content.
2. **Hoist the operative conditions.** Scan the body *and the `Why:`* for
   any "when / unless / except" that changes behavior, and state it
   explicitly in the rule. This is where careless promotions lose precision
   — a boundary left behind in narrative gets dropped.
3. **Compress the `Why:` to one clause and usually keep it** — a bare
   directive gets over-applied; a one-line rationale is what lets the reader
   generalize to cases the rule didn't enumerate. Keep it in the rule iff it
   steers edge cases; the full `Why:` goes to the ledger verbatim either way.
4. **Drop to the ledger:** provenance, dates, session references, the origin
   memory's `name:`. The rewrite is lossy in the ambient copy, lossless
   overall — demotion reconstructs the memory from rule + row.
5. **The stand-alone test (the go/no-go):** the rule text *alone* — no
   conversation, no provenance — must produce the memory's intended behavior
   on the known edge cases. **If hoisting conditions can't make it pass at
   rule size, the memory was never a rule candidate**: framework-shaped
   knowledge stays a memory (or graduates to a skill if it's procedural).
   Unrecoverable precision loss is the selection signal, not a cost to eat.

Rule files carry no frontmatter and no marker comments — an HTML comment in
a rule still loads as tokens every session. The `rules/memory/` location
*is* the membership marker; the ledger, keyed by filename, carries the rest.

## The ledger

`~/.claude/memory/rules-ledger.md` — **in the memory store, never in the
rules directory** (anything `.md` under `~/.claude/rules/` becomes ambient
context; a ledger there would be a permanent token tax). Living in the store
also means the store's git checkpointing versions it, so promotions are
diffable and reversible. `memory-sweep` creates it on the first promotion:

```markdown
# Promoted-rules ledger

Not a memory entry — infrastructure for the promoted-rules tier under
~/.claude/rules/memory/ (see RULES.md in the claude-global-memory repo).
Maintained by memory-sweep; one row per promoted rule.

| Rule file | Origin memory (name) | Promoted | Why (verbatim from the memory) | Demote when |
|---|---|---|---|---|
```

Reconciliation is part of every `memory-sweep` rules pass: a file under
`rules/memory/` with no row, or a row with no file, is drift to resolve —
in both directions.

## Demotion

The round trip back: reconstruct the memory from the rule text plus the
ledger row's `Why`, file it in the store, delete the rule file and the row.
Demote when a rule turns out to be conditional after all (first observed
project conflict is automatic evidence), goes stale, gets superseded, or the
tier needs the budget back. A rule the user simply deletes by hand shows up
as row-without-file at the next sweep — treat that as a demotion request and
offer the reconstruction.

## What never happens

- Bootstrap never touches `~/.claude/rules/memory/` or the ledger.
- A promotion is never auto-applied — `memory-sweep` proposes the drafted
  rule text beside the source memory, and a human ticks it.
- A fact never lives in both tiers — promotion moves, never copies. A
  leftover memory entry duplicating a live rule is drift for the sweep to
  flag.
- This repo never ships promoted-rule content. Like memories, promoted
  rules are personal and machine-local; the scaffold ships only this policy
  and the sweep logic that enforces it.
