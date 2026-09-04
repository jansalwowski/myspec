---
name: "memory-create"
description: "Use when an approved insight needs writing to memory — the shared path called by session-complete, memorize and memorify. Handles procedural, semantic and episodic types with a consolidation check. Do NOT use for user-facing capture (memorize, memorify) or without approval."
---

# Memory Create

## Prerequisites

- Completed session log with `status: completed`, OR direct capture with user approval.

## Constraints

- Index entries contain keywords/topics ONLY — never solutions or procedures
- Memory files use type-appropriate format:
  - **Procedural**: Steps (do this, verify that)
  - **Semantic**: Facts (what is true, source, implication)
  - **Episodic**: Narrative (context, decision, outcome, consequence)
- Code-specific memories MUST include file + grep pattern anchors for staleness detection
- Set `related` to cross-reference memories discovered during the consolidation check; empty is fine for a first capture in a new area

## Workflow

### 1. Determine Memory Type

Based on caller input or session analysis:

- **Procedural**: A reusable pattern for how to do (or not do) something
- **Semantic**: A fact about the codebase, API, dependency, or environment
- **Episodic**: A significant event, decision, or outcome worth recording

### 2. Consolidation Check (ADD / UPDATE / NO-OP)

**Before claiming an ID or drafting a file, check whether the insight already exists.** This prevents append-style growth where related rules accumulate as separate entries that later sanitize has to merge.

1. Read `${aiDir}/memory/{type}/index.md` — scan the Hook column for overlap with the planned memory
2. For each candidate row, read the linked memory file body
3. Decide:
   - **NO-OP** — an existing memory already covers this. Tell the user "Already covered by `{id}` — open it?" and **stop without creating**.
   - **UPDATE** — an existing memory is close but missing this nuance. Propose a verbatim diff (new lines to append/insert into the existing file). **Do not create a new file**; bump the existing memory's `validated`/`verified` date instead. No ID is claimed.
   - **ADD** — truly novel. Proceed to Step 3.

Bias toward UPDATE when the rule overlaps; only ADD when the trigger scenario, anchor, or polarity meaningfully differs.

### 3. Claim an ID (ADD only)

```bash
.claude/lib/memory-claim-id.sh <procedural|semantic|episodic>
```

Prints the claimed ID (e.g. `P053`) and nothing else. It runs the memory conformance check first, locks the main checkout, scans every worktree and every branch (local and remote), and records the claim before the file exists.

**Fail closed.** Never read the index and take the next free number: two sessions doing that pick the same ID, and because their rows land on different lines the tables auto-merge with no conflict. Every collision on record came from exactly that fallback, in a project where the script was absent or could not read the files.

| Result | Meaning | Do |
|--------|---------|----|
| Prints `P053` | Claimed | Use that ID |
| `No such file` — script missing | Project predates the allocator | Stop. Tell the user to run `/myspec:update`, then retry |
| Exit 3 with `ERROR …` lines | Conformance errors: duplicate IDs, memories without `hook:`, malformed anchors | Stop. Show the errors. `memory-index.mjs --backfill` derives missing hooks; the rest are per-file fixes |
| Exit 1 — could not acquire the lock | Another session held it for > 10 s | Retry once; if it persists, report it |

In the stop cases, do not hand-pick an ID and do not create the file. If the user later abandons the draft, the claimed number stays unused — a gap in the sequence is harmless and there is nothing to release.

### 4. Draft Memory File

Use the type-appropriate template from `${aiDir}/.templates/memory-{type}.md`:

**If procedural:**
- Extract: problem, failed approaches, successful approach, root cause
- Structure as: Procedure (Do This) -> Why -> What Fails -> Verification
- Set `polarity`: positive (pattern to follow) or negative (anti-pattern)
- Set `triggers`: keywords from the problem space (error messages, component names, symptoms)
- Set `not_for`: 2-3 specific exclusions
- Set `anchors`: file + grep pattern if code-specific
- Set `related`: IDs of related semantic/episodic memories (e.g., ["S001", "E003"])

**If semantic:**
- Extract: the factual statement, source, implication
- Keep concise -- 1-3 sentences for the fact
- Set `topic`: domain keyword (e.g., google-maps, prisma, auth)
- Set `anchor`: file + pattern to check staleness
- Set `related`: IDs of related procedural/episodic memories (e.g., ["P009", "E001"])

**If episodic:**
- Extract: context, decision, outcome, consequence
- Set `outcome`: success | failure | partial | abandoned
- Set `persistent: true` only if this has indefinite relevance
- Default `persistent: false` -- will auto-archive after 30 days
- Set `related`: IDs of related procedural/semantic memories (e.g., ["P009", "S001"])

### 5. Update Type-Specific Index

Set `hook:` in the new memory's frontmatter — a one-line keyword/topic summary — then regenerate and verify:

```bash
node .claude/lib/memory-index.mjs          # or `yarn memory:index` where wired up
node .claude/lib/memory-index.mjs --check  # must print: memory indexes are up to date
```

The index tables are generated from the memory files, so the row is derived from `hook:` rather than hand-written. The generator refuses to run while any memory lacks `hook:` — that is the check working, not a reason to edit the table by hand. If the generator is missing, the project predates it: run `/myspec:update`.

**CRITICAL**: the hook shows keywords/topics/summaries ONLY, never solutions or procedures. It is what an agent scans; the file body is what it loads on a match.

A merge conflict in `index.md` is not a merge to reason about — keep either side and re-run the generator.

### 6. Present to User for Refinement

Show the drafted memory. Ask:
"Does this capture the key insight? Any adjustments?"

### 7. Write Final Files

Save memory file and updated index.
Update `validated`/`verified` date in memory frontmatter.

### 8. Consider Layer 1 Promotion

If the memory is critical enough to always be in context:
- Ask user: "Should this be promoted to the global index (${aiDir}/memory/index.md)?"
- If yes: add a one-line summary to the appropriate section.

## Verification Checklist

- [ ] Memory type correctly identified (procedural/semantic/episodic)
- [ ] Consolidation check performed before any ID was claimed (ADD / UPDATE / NO-OP decision recorded)
- [ ] If UPDATE / NO-OP: no new file created, no ID claimed
- [ ] If ADD: memory file uses correct template from `${aiDir}/.templates/memory-{type}.md`
- [ ] ID came from `memory-claim-id.sh`; a missing script or an exit-3 refusal stopped the write instead of being worked around
- [ ] `hook:` set in frontmatter; index regenerated and `--check` clean
- [ ] Index row contains keywords/topics only — no solutions leaked
- [ ] `anchors` field set for code-specific memories
- [ ] `related` field cross-references other memory types
- [ ] User approved the drafted memory before final write
- [ ] `validated`/`verified` date set in frontmatter

## When NOT to Use

- Session didn't reveal non-obvious insights
- Problem was a simple typo or configuration
- User declined memory creation
