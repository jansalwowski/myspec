# `/myspec:memory-optimize` — examples

Grooms the *project* memory tree at `ai/memory/{procedural,semantic,episodic}/`. Re-anchors memories whose code moved, retunes ones nobody can find, merges pairs that collide, consolidates aged-out episodes, and retires what no longer holds — always behind an audit table and a confirmation.

> **Related**: [`/myspec:memory-sanitize`](memory-sanitize.md) grooms the *user-level* auto-memory store at `~/.claude-personal/projects/<encoded_cwd>/memory/`. Different store, different objective: sanitize optimizes bytes in context (it compresses bodies), optimize protects retrieval (it never touches body length, because project memory bodies load only on a match).

**Contents**

- [Routine pass — mixed buckets](#routine-pass--mixed-buckets)
- [A memory that never fired — retune, not drop](#a-memory-that-never-fired--retune-not-drop)
- [Colliding triggers — merging two procedurals](#colliding-triggers--merging-two-procedurals)
- [Episode decay — consolidate vs. expire](#episode-decay--consolidate-vs-expire)
- [Nothing to do — healthy store](#nothing-to-do--healthy-store)

---

## Routine pass — mixed buckets

The high-yield case: a store that has been written to for a year and never groomed. Code has moved under it, two memories have grown into each other, and several episodes aged out without anyone noticing.

### Setup

`ai/memory/` holds 14 procedural, 9 semantic, and 6 episodic entries. A `packages/db` refactor landed six weeks ago and moved several files.

### Invocation

```
/myspec:memory-optimize
```

### Skill flow

#### 1. Announce + inventory

> Running memory optimization audit.

```bash
node .claude/lib/memory-index.mjs --check
# stale: ai/memory/procedural/index.md
# 1 index file(s) out of date.
```

Stale table → regenerate before triage, so the audit reads files rather than a lagging table. Then reads `ai/memory/index.md` (Layer 1), the three type indexes, and all 29 memory files.

Structural faults reported up front:

- `E004` lists `related: [P031]`, but `P031` lists `related: []` — one-way link
- No duplicate IDs, no orphaned `status: superseded` files — either would land in REPAIR, which is reported and asked, never auto-fixed (renumbering rewrites every citation)

#### 2. Per-entry checks

Anchor liveness runs in two steps, and the second step is what keeps the pass from being destructive:

```bash
# S014 — anchor: {file: packages/db/src/client.ts, pattern: datasourceUrl}
[ -f packages/db/src/client.ts ]          # fail — file is gone
git grep -l datasourceUrl -- . ":(exclude)ai"
# packages/db/src/prisma/client.ts        # the fact survived, the file moved
```

```bash
# S007 — anchor: {file: apps/web/src/lib/flags.ts, pattern: LEGACY_FLAG_TABLE}
[ -f apps/web/src/lib/flags.ts ]          # fail
git grep -l LEGACY_FLAG_TABLE -- . ":(exclude)ai"
# (no output)                             # the thing the fact described is gone
```

Same failing first check, opposite conclusion.

Other signals picked up in the same sweep:

- `P022` — `validation_count: 0` since `created: 2025-12-04`, anchor still live
- `P007` / `P019` — share `hydration` and `ssr` in `triggers`, same `feature: checkout`
- `E011` — `persistent: false`, `date: 2026-04-02`, `related: []`
- `P031` — `validation_count: 6`, absent from Layer 1

#### 3. Audit report

```
## Memory Optimization Audit

Structural faults (reported above the table, never auto-fixed):
- none

| # | id   | bucket      | signal                                                        | action                          |
|---|------|-------------|---------------------------------------------------------------|---------------------------------|
| 1 | S014 | RE-ANCHOR   | file gone; pattern lives at packages/db/src/prisma/client.ts   | rewrite anchor + index cell     |
| 2 | S007 | DROP-stale  | pattern absent repo-wide; created 2025-06-18; 0 citations      | supersede, body = reason        |
| 3 | P022 | RETUNE      | validation_count 0 since 2025-12-04, anchor live               | rewrite triggers to symptoms    |
| 4 | P019 | MERGE       | shares [hydration, ssr] with P007 (vc 0 vs 4)                  | fold into P007, stub P019       |
| 5 | E011 | CONSOLIDATE | 151d old, persistent false, nothing extracted yet              | new semantic memory, stub E011  |
| 6 | P031 | PROMOTE     | validation_count 6, absent from Layer 1                        | add one line to ai/memory/index.md |
| 7 | E004 | RELINK      | related [P031] not reciprocated                                | add E004 to P031.related        |

Summary: 1 re-anchor, 1 retune, 1 relink, 1 promote, 1 merge, 1 consolidate, 1 drop.
Index rows: 29 → 26 after execution.
```

#### 4. Confirm and execute

Non-destructive rows (1, 3, 6, 7) go into one `AskUserQuestion` with every rewrite shown verbatim. Destructive rows (2, 4, 5) are confirmed one at a time, each with its citation grep in the message:

```
Row 2 — retire S007?

grep -rn "S007" ai/ .claude/
  (no matches outside ai/memory/semantic/S007-legacy-flag-table.md)

Created 2025-06-18 (439 days), anchor pattern absent repo-wide.
The file stays on disk with status: superseded — the ID keeps resolving.
```

**The index gotcha, in practice.** Re-anchoring S014 takes two edits, not one:

```diff
  # ai/memory/semantic/S014-prisma-datasource-url.md
  anchor:
-   file: packages/db/src/client.ts
+   file: packages/db/src/prisma/client.ts
    pattern: datasourceUrl
- verified: 2026-01-12
+ verified: 2026-08-31
```

```diff
  # ai/memory/semantic/index.md
- | [S014](S014-prisma-datasource-url.md) | prisma datasource resolution | packages/db/src/client.ts |
+ | [S014](S014-prisma-datasource-url.md) | prisma datasource resolution | packages/db/src/prisma/client.ts |
```

The generator prefers the row already in the index for the Anchor column, so editing frontmatter alone would leave the dead path in the table forever. `hook` resolves the other way — frontmatter wins — so a RETUNE only touches the file.

#### 5. Verify

```bash
node .claude/lib/memory-index.mjs
node .claude/lib/memory-index.mjs --check   # exit 0
grep -rn "S007\|P019\|E011" ai/ .claude/    # every retired ID still resolves to a file
```

#### Final summary

> Re-anchored 1, retuned 1, relinked 1, promoted 1, merged 1, consolidated 1, retired 1. Index rows 29 → 26. No files deleted.

### Why this example matters

- **A dead path is not a dead memory.** S014 and S007 fail the identical first check and end in opposite buckets. A pass that only checked file existence would have deleted a true fact about Prisma and kept nothing of value in exchange.
- **Retirement is a stub, never `rm`.** `memory-claim-id.sh` derives the next ID from the filenames on disk, and only writes its registry floor when `jq` is installed. Delete the highest-numbered file and the next session can be handed an ID that is already cited in a session archive.
- **The Anchor column is sticky.** This is the one thing about the index generator that a groomer has to know, and it is invisible until someone notices the table still points at a file deleted three months ago.
- **Audit-then-confirm, with the grep in the message.** The user should not have to take "uncited" on trust for a row that removes something.

---

## A memory that never fired — retune, not drop

`validation_count: 0` looks like the clearest possible delete signal. It usually is not.

### Setup

```yaml
# ai/memory/procedural/P022-skill-dispatch-silent-failure.md
id: P022
created: 2025-12-04
validated: 2025-12-04
validation_count: 0
triggers: [SkillRunner, dispatchTask, invokeSkill]
anchors: [{file: "packages/agent/src/skill-runner.ts", pattern: "resolveSkillName"}]
```

Eight months old, never once matched by `/myspec:memory-lookup`.

### Skill flow (excerpt)

The anchor resolves — file and pattern both present — so the pattern it describes is still real code. The `triggers` are the problem: every one of them is an implementation noun from inside the module. Nobody types `SkillRunner` when a skill silently fails to fire; they type what they saw.

```diff
- triggers: [SkillRunner, dispatchTask, invokeSkill]
+ triggers: ["skill did not fire", "unknown skill name", "InputValidationError", "skill silently skipped"]
  not_for: ["skill body errors after invocation", "MCP tool failures"]
- validated: 2025-12-04
+ validated: 2026-08-31
```

Bucket: RETUNE. The memory stays; `validation_count` stays at 0 and gets another 90 days to prove itself.

### Why this example matters

- **`validation_count: 0` measures findability, not truth.** The anchor already told us the knowledge is current. Dropping here deletes working knowledge because it was filed under the wrong words.
- **Retirement needs two failures, not one.** A memory is only a drop candidate after a retune that still cannot name a scenario that would surface it.
- **Triggers are written from the symptom side.** The rule generalizes past this memory: index rows are matched against what a person hits, not against what the code is called.

---

## Colliding triggers — merging two procedurals

Two memories that fire on the same words are worse than one memory, because lookup loads both and picks by coin flip.

### Setup

```
P007  feature: checkout  vc: 4  triggers: [hydration mismatch, ssr, next-app-router]
P019  feature: checkout  vc: 0  triggers: [hydration, useEffect, ssr]
```

Two shared trigger entries inside one feature → MERGE candidate.

### Skill flow (excerpt)

Survivor is `P007` (higher `validation_count`; ties break to the lower ID). It absorbs the union of triggers and the loser's `related`, and gets a sharpened `not_for` so the two original cases stay distinguishable:

```diff
  # ai/memory/procedural/P007-hydration-mismatch.md
- triggers: [hydration mismatch, ssr, next-app-router]
+ triggers: [hydration mismatch, hydration, ssr, next-app-router, useEffect]
- not_for: ["client-only components"]
+ not_for: ["client-only components", "hydration warnings from third-party embeds"]
```

The citation grep decides how P019 leaves:

```bash
grep -rn "P019" ai/ .claude/
# ai/memory/sessions/archive/2026-02-14-checkout-hydration.md:41
```

Cited — so the file stays and the ID keeps resolving:

```markdown
---
id: P019
type: procedural
status: superseded
---

Merged into [P007](./P007-hydration-mismatch.md).
```

`status: superseded` is all it takes to leave the table: the index generator filters those files out, and `memory-claim-id.sh` still counts the file when computing the next free ID.

### Why this example matters

- **The collision test is mechanical.** Two shared entries in `triggers` within one feature — no judgment call, no reading required to *find* the pair (only to merge it).
- **Merging is not deletion.** A session archive from February still cites P019. The stub keeps that link honest.
- **The survivor has to stay precise.** Taking the union of triggers without sharpening `not_for` produces one memory that matches more and says less.

---

## Episode decay — consolidate vs. expire

`persistent: false` episodes are promised a 30-day life in the template. Nothing has ever enforced it, so aged episodes accumulate in the table and dilute every episodic scan.

### Setup

```
E011  date: 2026-04-02  persistent: false  outcome: partial  related: []
E004  date: 2026-05-20  persistent: false  outcome: success  related: [P031]
```

### Skill flow (excerpt)

Same age signal, different dispositions, decided by whether the durable lesson was ever extracted:

**E011 → CONSOLIDATE.** 151 days old, nothing extracted. The episode narrates a failed Redis session-store migration; the durable part is one fact about connection limits. Route through `/myspec:memory-create` (which runs its own ADD / UPDATE / NO-OP check), then stub the episode:

```markdown
Consolidated into [S021](../semantic/S021-redis-connection-ceiling.md).
```

**E004 → EXPIRE.** Already consolidated — `related: [P031]`, and P031 carries the procedure. Nothing to extract; stub it:

```markdown
Expired 2026-08-31 — knowledge lives in [P031](../procedural/P031-checkout-retry-budget.md).
```

Both drop out of the episodic table on the next regeneration; both files stay on disk.

### Why this example matters

- **Age alone never decides.** The question is whether the lesson was extracted, which `related` answers directly.
- **Consolidation goes through `memory-create`.** Writing the semantic memory by hand skips the consolidation check and the ID lock — the two things that keep parallel sessions from colliding.
- **This is the check that does not belong on the hot path.** `/myspec:memory-preflight` currently flags decayed episodes mid-scan, while the agent is trying to start real work. Batching it here is the point of the skill.

---

## Nothing to do — healthy store

### Setup

A store groomed six weeks ago. 22 entries, all anchored, no episodes past 30 days.

### Invocation

```
/myspec:memory-optimize
```

### Skill flow

> Running memory optimization audit.

```bash
node .claude/lib/memory-index.mjs --check   # exit 0
```

All 14 anchors resolve on the first check. No `triggers` pair shares two entries. No `related` id dangles or points one way. Every episode is inside 30 days or marked `persistent: true`.

```
## Memory Optimization Audit

No action required. 22 entries checked: 14 anchors live, 0 collisions, 0 decayed episodes, 0 broken links.

Watch list (no action proposed):
| id   | note                                                        |
|------|-------------------------------------------------------------|
| P018 | validation_count 0, created 2026-07-19 — inside the 90d grace window |

Index rows: 22 → 22.
```

### Why this example matters

- **A clean pass writes nothing, including the index.** No regeneration, no timestamp bumps — a run that leaves a diff on a healthy store trains people to stop running it.
- **The watch list is not a finding.** P018 will become a RETUNE candidate in October if it still has not fired. Reporting it now, without proposing an action, is the difference between a useful signal and noise.
