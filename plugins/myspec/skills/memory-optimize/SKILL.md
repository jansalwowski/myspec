---
name: memory-optimize
description: "Use to groom the project memory tree at ${aiDir}/memory/ — dead anchors, memories that never fire, colliding triggers, expired episodes, index drift. Keywords: groom memories, memory audit, stale anchor, re-anchor. Do NOT use for the user-level store (memory-sanitize)."
---

# Memory Optimize

Audit the project memory tree, triage every entry, and execute re-anchors, retunes, merges, consolidations, and retirements with explicit confirmation.

The target is **retrieval quality, not size**. Memory bodies load only when `/myspec:memory-lookup` matches a row, so a long body costs nothing; the store degrades through rotted anchors, blurred triggers, expired episodes crowding the tables, and hooks that leak the answer so the agent never opens the file. Never shorten a body to save tokens — that is `/myspec:memory-sanitize`'s job, on a different store with a different loading model.

**Announce at start:** "Running memory optimization audit."

## Hard rules

- Never `rm` a memory file. An entry that leaves the index gets `status: superseded` in its frontmatter and a one-line redirect body: the index generator filters superseded files out, and `memory-claim-id.sh` still counts the file when computing the high-water ID. Deleting the highest-numbered file hands the next session a colliding ID wherever `jq` is absent — the ID registry is only written when `jq` exists, and the filesystem scan is the fallback.
- Never retire a memory whose ID is cited outside its own file. `grep -rn "P019" ${aiDir}/ .claude/` — `memory/sessions/archive/`, feature docs, and other memories' `related:` all count as citations.
- Never hand-write index rows. Edit the files, then run `node .claude/lib/memory-index.mjs`; `--check` must exit 0 before reporting done.
- Never retire an entry created less than 30 days ago — a new memory has not had time to be matched even once, so `validation_count: 0` carries no signal yet. RE-ANCHOR, RETUNE, and RELINK are non-destructive and allowed at any age.
- A dead anchor path is not a dead memory — the second check in Step 2 decides.
- Out of scope: `~/.claude-personal/projects/<encoded_cwd>/memory/` (`/myspec:memory-sanitize`) and session logs — `.claude/state/sessions/` and `${aiDir}/memory/sessions/archive/` (`/myspec:session-clean`).

## Workflow

### Step 1: Inventory

1. Resolve `aiDir` from `.myspec.json` (`.aiDir`; the key is required since 2.0; when it is absent the tooling uses `.ai` and the setup doctor reports it).
2. Run `node .claude/lib/memory-index.mjs --check`. Exit 1 means the tables are stale — regenerate before triage, so the audit reads files rather than a lagging table.
3. Read `${aiDir}/memory/index.md` (Layer 1) and the three `${aiDir}/memory/{type}/index.md` tables.
4. Read every `P*.md`, `S*.md`, `E*.md`. Capture per entry: `id`, `hook`, `feature`, `related`, plus type fields — procedural: `polarity`, `triggers`, `not_for`, `anchors`, `validation_count`, `created`, `validated`; semantic: `topic`, `anchor`, `verified`; episodic: `outcome`, `persistent`, `date`.
5. Run `node .claude/lib/memory-doctor.mjs` and report its structural faults before triage: duplicate IDs on disk or on any branch (the failure `memory-claim-id.sh` exists to prevent; `status: superseded` tombstones are exempt), memories without `hook:`, malformed anchors, `related:` IDs with no matching file. Add anything the doctor cannot see: files already marked `status: superseded` that are still cited as live.

### Step 2: Per-entry checks

| Check | Applies to | How | Signal |
|---|---|---|---|
| Anchor liveness | P, S | `[ -f "$file" ] && grep -q "$pattern" "$file"` | pass → anchored |
| Anchor relocation | P, S | on failure: `git grep -l "$pattern" -- . ":(exclude)$aiDir"` | hit → RE-ANCHOR; no hit → DROP-stale |
| Never fired | P | `validation_count` is 0 and `created` > 90 days | RETUNE (see below) |
| Trigger collision | P | 2+ shared entries in `triggers` with another P of the same `feature` | MERGE candidate |
| Episode decay | E | `persistent: false` and `date` > 30 days | CONSOLIDATE or EXPIRE |
| Related graph | all | every id in `related` resolves, and the target lists this id back | RELINK |
| Hook leakage | all | row states a solution: imperative verb, "use X instead of Y", a code span, a file path | RETUNE |
| Feature orphan | all | `feature:` names something absent from `${aiDir}/features/index.yaml` | RELINK or clear the field |
| Layer 1 drift | all | Layer 1 line points at a superseded id; or `validation_count >= 3` and absent from Layer 1 | DEMOTE / PROMOTE — Layer 1 is always in context, so propose a PROMOTE only alongside the DEMOTE it displaces |

**A never-fired memory is a triggers bug until proven otherwise.** When `validation_count` is 0 but the anchor still resolves, the pattern is usually real and filed under keywords nobody types — implementation nouns instead of the symptom text. Rewrite `triggers` to what a person actually meets (error strings, observed behavior) and keep the memory. Retire it only after a retune that still cannot name a scenario that would surface it.

### Step 3: Buckets

| Bucket | Trigger | What it writes |
|---|---|---|
| KEEP | accurate, anchored, discoverable | nothing |
| RE-ANCHOR | anchored file moved, pattern still present | frontmatter anchor + index Anchor cell (Step 5) + `validated` / `verified` |
| RETUNE | triggers or hook mismatched to how the problem is met | `triggers`, `not_for`, `hook` |
| RELINK | dangling or one-way `related`, orphaned `feature` | `related` on both ends |
| MERGE | trigger collision inside one feature | survivor absorbs; loser becomes a superseded stub |
| CONSOLIDATE | episode > 30 days carrying a durable lesson | **REQUIRED:** new P or S via `/myspec:memory-create` — it owns the ID lock and the consolidation check; episode becomes a stub |
| EXPIRE | episode > 30 days, `persistent: false`, nothing durable left | superseded stub |
| PROMOTE / DEMOTE | Layer 1 membership changed | one line in `${aiDir}/memory/index.md` |
| DROP-stale | anchor pattern gone repo-wide, older than 30 days, uncited | superseded stub, body replaced by the reason |
| REPAIR | two files claim one ID, or a `status: superseded` file is still cited as live | never auto-fixed — report both files and ask; renumbering rewrites every citation, and un-superseding silently re-enters the table |

**Merge resolution:** survivor is the higher `validation_count`, tie broken by lower ID. The survivor takes the union of `triggers`, absorbs the loser's `related`, and gets `not_for` sharpened enough to keep the two original cases distinguishable. The loser's body collapses to `Merged into [P007](./P007-{slug}.md).`

### Step 4: Report

Print one table before any mutation:

```
## Memory Optimization Audit

Structural faults (reported above the table, never auto-fixed):
- none

| # | id | bucket | signal | action |
|---|---|---|---|---|
| 1 | S014 | RE-ANCHOR | anchor file gone; pattern lives at packages/db/src/prisma/client.ts | rewrite anchor, bump verified |
| 2 | P022 | RETUNE | validation_count 0 since 2025-12-04, anchor live | triggers → symptom text |
| 3 | P019 | MERGE | shares [hydration, ssr] with P007 (vc 4 vs 0) | fold into P007, stub P019 |
| 4 | E011 | CONSOLIDATE | 150d, persistent false, related [] | extract 1 semantic fact, stub E011 |
| 5 | E004 | EXPIRE | 103d, already consolidated into P031 | stub E004 |
| 6 | S007 | DROP-stale | pattern absent repo-wide, created 2025-08-11, 0 citations | stub with reason |
| 7 | P031 | PROMOTE | validation_count 6, absent from Layer 1 | add Layer 1 line |

Summary: 1 re-anchor, 1 retune, 1 merge, 1 consolidate, 1 expire, 1 drop, 1 promote
```

### Step 5: Confirm and execute

Batch the non-destructive buckets (RE-ANCHOR, RETUNE, RELINK, PROMOTE, DEMOTE) into a single `AskUserQuestion`, with every proposed rewrite shown verbatim in the message or in an option `description`. Confirm MERGE, CONSOLIDATE, EXPIRE, and DROP-stale one at a time, each with its citation-grep result shown.

**Index gotcha:** the generator prefers the row already in the index for the Anchor column — an author who blanked that cell chose to. Editing frontmatter alone leaves the stale path in the table permanently, so every RE-ANCHOR edits the frontmatter *and* the row's Anchor cell before regenerating. `hook` resolves the other way (frontmatter wins), so a RETUNE only touches the file.

Execution order:

1. File edits (anchors, triggers, hooks, `related`, merge survivors).
2. Superseded stubs — add `status: superseded`, replace body with the one-line redirect or reason.
3. Layer 1 edits in `${aiDir}/memory/index.md`.
4. `node .claude/lib/memory-index.mjs`.
5. `node .claude/lib/memory-index.mjs --check` — must exit 0.
6. If it still exits 1, stop and show the drifting index. The generator disagrees with the files; hand-editing the row to make it pass violates the third hard rule and hides the real edit that went wrong.

## Verification Checklist

- [ ] `--check` run before triage; stale tables regenerated first
- [ ] Structural faults (duplicate IDs, superseded files still cited as live) reported above the audit table and left to the user — none silently repaired
- [ ] Every P and S anchor checked in both directions (path, then pattern repo-wide)
- [ ] Every retirement preceded by an ID-citation grep across `${aiDir}/` and `.claude/`, result shown to the user
- [ ] No memory file deleted — retirements are `status: superseded` stubs, IDs still resolve
- [ ] No entry younger than 30 days retired
- [ ] Every RE-ANCHOR edited both the frontmatter anchor and the index Anchor cell
- [ ] Every index row scanned for a leaked solution; each leaking `hook` rewritten to keywords only
- [ ] Merge survivors carry the union of `triggers` and a `not_for` that separates the merged cases
- [ ] Consolidated episodes produced a real P or S memory before the episode was stubbed
- [ ] `related` links resolve in both directions after RELINK
- [ ] `node .claude/lib/memory-index.mjs --check` exits 0
- [ ] Summary line printed: re-anchored / retuned / merged / consolidated / expired / dropped / promoted, and index rows before → after
