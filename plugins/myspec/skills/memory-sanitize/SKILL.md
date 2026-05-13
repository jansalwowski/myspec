---
name: "memory-sanitize"
description: "Use when grooming the user-level auto-memory store at ~/.claude-personal/projects/ — stale entries, bloated bodies, duplicates, contradictions, or memories that belong in CLAUDE.md/rules instead. Keywords: sanitize memory, prune memories, compress memory, memory triage, memory groom. Do NOT use for project ${aiDir}/memory/ (use memory-create), or for searching memories (use memory-lookup)."
---

# Memory Sanitize

Audit the user-level auto-memory store for this project, triage each entry, and execute drops / promotions / merges / compressions with explicit confirmation.

**Critical constraints:** never auto-promote (always show destination + exact insertion text); never delete a still-cited memory (grep first); skip DROP for entries <7 days old (COMPRESS is allowed at any age); do not touch project `${aiDir}/memory/`. See [Hard guards](#hard-guards) for full set.

**Companion rule:** `.claude/rules/auto-memory-style.md` defines the length budget, cut list, and worked example that COMPRESS rewrites must conform to.

## Scope

- **In scope:** `~/.claude-personal/projects/<encoded_cwd>/memory/` (user-level auto-memory). The encoded cwd is the absolute project path with both `/` and `_` replaced by `-` — computed as `pwd | tr '/_' '-'`.
- **Out of scope:** project `${aiDir}/memory/{procedural,semantic,episodic}/` (myspec system).

## Workflow

### Phase 1 — Inventory

1. Resolve memory dir. First **canonicalize to the main worktree** so agent worktrees do not splinter the memory store: set `MAIN=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)`; if `MAIN` ends in `.git`, set `ROOT=$(dirname "$MAIN")`, otherwise `ROOT=$(pwd)`. Then memory dir = `~/.claude-personal/projects/$(printf '%s' "$ROOT" | tr '/_' '-')/memory/`. Refuse if missing.
2. Read `MEMORY.md` and every `*.md` entry it links to.
3. Integrity check: list orphans (files not in `MEMORY.md`) and broken links (entries pointing to missing files). Report both.
4. Index-line hygiene: flag any `MEMORY.md` lines whose length exceeds 150 chars (per `CLAUDE.md` auto-memory guidance — long hooks bury the takeaway). Surface in the Phase 4 report as **REWRITE-HOOK** candidates. This is a write-side fix, not a drop/promote — propose a shorter hook for each flagged entry.

### Phase 2 — Per-entry triage

For each memory, run cheap verifications and assign ONE bucket:

| Bucket | Trigger |
|---|---|
| **KEEP** | Claim still accurate, non-obvious, project-specific, already within length budget |
| **DROP-stale** | Cited file/symbol/dep no longer exists or contradicts current code |
| **DROP-trivial** | True but generic enough that any reasonable agent does it anyway |
| **DROP-duplicate** | Strongly overlaps another memory or a `.claude/rules/` file |
| **PROMOTE** | Belongs in CLAUDE.md, `.claude/rules/{X}.md`, or a specific `.claude/skills/{X}/SKILL.md` body |
| **MERGE** | Fires in the same scenario as ≥1 other memory (defer to Phase 3) |
| **COMPRESS** | Claim is still accurate but body exceeds length budget (see `.claude/rules/auto-memory-style.md`) or contains cut-list items (full code blocks where a one-liner suffices, originating-incident narrative, PR refs, "where applied" sections, date-bound references) |
| **CONFLICT** | Contradicts another KEEP/COMPRESS memory (e.g. one says "always X", another says "never X for case Y"). Defer pairwise resolution to Phase 3. |

**Cheap verifications:**
- File paths cited → check exists
- Specific symbols/functions → grep once
- Dep version claims → check `package.json` or relevant config
- Length budget → `wc -l` against the per-type cap in `auto-memory-style.md`
- Skip deep semantic verification — flag for human review instead

**Age floor by type:**
- **Feedback / semantic / reference:** skip DROP for files modified <7 days ago. Recent memories haven't earned skepticism yet. **COMPRESS is exempt from this floor** — rewriting for length is non-destructive and the survivor still carries the same rule.
- **Project type:** include regardless of age. Project memories are point-in-time snapshots and decay fast — review them as soon as drift is suspected.

### Phase 3 — Cluster pass + conflict pairing

Over the KEEP+PROMOTE+COMPRESS set:

- **Clusters** — group by trigger scenario (e.g. "fresh worktree onboarding", "Stop hook misfires", "OOM during build"). Any cluster of ≥2 → propose MERGE into one consolidated file.
- **Conflicts** — surface every pair flagged CONFLICT. Newer file wins by default (`stat -f %m` mtime comparison). Older becomes `status: superseded` with body collapsed to a single line linking the survivor; remove from `MEMORY.md` but keep the file on disk as audit trail.

### Phase 4 — Report

Print one table grouped by bucket. For each:

- **DROP**: one-line reason
- **PROMOTE**: candidate destination file + section
- **MERGE**: cluster name + member files
- **COMPRESS**: source line count → proposed line count → % reduction; show proposed rewrite verbatim (or in `option.description` when batching via `AskUserQuestion`)
- **CONFLICT**: pair + winner + loser

Append a run summary line: `Compressed N entries, total reduction X%, store now Y lines (was Z).`

### Phase 5 — Confirm and execute

**Drops (low-risk, batch):** one confirmation for all drops.
- Before deleting: `grep -r {filename}` across the repo, **excluding agent worktree directories** (`.claude/worktrees/`, `.git/worktrees/`) and `node_modules/`. Worktrees are throwaway shadow checkouts containing stale copies from main; they inflate citation counts and produce false-positive KEEPs. Use `grep -r {filename} ${aiDir}/ .claude/ apps/ packages/ --exclude-dir=worktrees --exclude-dir=node_modules --exclude-dir=.prisma` (adjust paths for the project layout). If any active doc/spec/rule still cites the memory, refuse the drop and reclassify as KEEP.

**Promotions (medium-risk):** before applying, show:
- Source memory full text
- Destination file + insertion location (which section, after which line)
- Exact text to be inserted (verbatim, not "I will summarize…")

**Merges (medium-risk):** before applying, show:
- Proposed merged-file path + content
- List of source files to delete

**Compressions (low-risk):** before applying, show:
- Source memory full text
- Proposed rewrite verbatim
- Line count delta (`41 → 11 lines, 73% reduction`)
- Same single-batch confirmation rule as promotions

**Conflicts (medium-risk):** before applying, show:
- Both source memories side-by-side
- Which one survives (newer by default; user can override)
- The one-line `Superseded by [{survivor}](./{survivor}).` stub that replaces the loser's body
- Confirm the loser's `MEMORY.md` line will be removed (the file stays on disk)

**Confirmation flow:** a single `AskUserQuestion` call covering all drops + promotions + merges + compressions + conflicts is acceptable **provided the verbatim insertion text (and merged-file / rewritten-file / superseded-stub content) is in the same message** — either inline above the question or in the option `description` field. Don't ask twice when the user already has the text in front of them. Ask per-action only when narrative context (long source memory, multi-block insertion) won't fit alongside the question.

### Phase 6 — Update index and verify

After every executed action:
1. Update `MEMORY.md` (remove dropped/merged/superseded entries, update merge survivors, leave COMPRESS index lines untouched unless they exceed 150 chars)
2. Verify: `grep -c '^- \[' MEMORY.md` + (count of files with `status: superseded`) equals `ls memory/ | grep -vE '^(MEMORY\.md|audit-)' | wc -l`. Audit reports are archived in the same directory and must be excluded from the entry-file count. Superseded files stay on disk as audit trail and are counted but not indexed.
3. Optional: archive the triage report to `~/.claude-personal/projects/<encoded_cwd>/memory/audit-{YYYY-MM-DD}.md`. The report **body** must reference paths via `<repo_root>` and `<encoded_cwd>` placeholders — never paste the resolved absolute form (the report may be shared or committed by the user).

## Hard guards

- **Never auto-promote.** Destination + exact insertion text shown before each promotion.
- **Never auto-rewrite (COMPRESS).** Proposed rewrite shown verbatim before each compression. The agent must conform to `.claude/rules/auto-memory-style.md` — no creative reinterpretation, only mechanical removal of cut-list items.
- **Never delete a still-cited memory.** Grep across `${aiDir}/`, `.claude/` (excluding `.claude/worktrees/`), `apps/`, `packages/` before any rm.
- **MEMORY.md edits are atomic with file deletes.** Never leave the index out of sync.
- **Don't DROP feedback/semantic/reference entries <7 days old.** COMPRESS is allowed at any age. Project-type entries are exempt from the floor — they decay by design.
- **CONFLICT supersession is non-destructive.** The loser's file stays on disk with a one-line stub; only the `MEMORY.md` line is removed.
- **Don't touch the project's `${aiDir}/memory/`.** Separate system, separate skill.

## Promotion routing reference

| Memory pattern | Destination |
|---|---|
| Output style / response formatting | `CLAUDE.md` Core Principles |
| Tool selection (e.g. AskUserQuestion preference) | `CLAUDE.md` Core Principles |
| Workflow phase behavior (e.g. suggest next skill) | `.claude/rules/workflow.md` |
| Backend-specific pattern | `.claude/rules/backend.md` |
| Frontend-specific pattern | `.claude/rules/frontend.md` |
| Lint/TS rule | `.claude/rules/lint-and-types.md` |
| Dep-management policy (visual regression, plan location, cluster rules) | `.claude/rules/deps.md` |
| Skill prerequisite or workflow constraint | `.claude/skills/{name}/SKILL.md` body |
| Skill-authoring meta-rule | `.claude/rules/skill-optimization.md` |

If the destination is ambiguous, leave as KEEP and flag in the report.

## Verification checklist

```bash
# After execution:
INDEX_COUNT=$(grep -c '^- \[' "$MEM_DIR/MEMORY.md")
FILE_COUNT=$(ls "$MEM_DIR" | grep -vE '^(MEMORY\.md|audit-)' | wc -l)
SUPERSEDED=$(grep -l '^status: superseded' "$MEM_DIR"/*.md 2>/dev/null | wc -l)

# Active entries (indexed) + superseded stubs (kept as audit trail) should sum to file count.
echo "$((INDEX_COUNT + SUPERSEDED)) should equal $FILE_COUNT"
```

- [ ] Every drop preceded by repo-wide grep for live citations
- [ ] Every promotion shown with verbatim insertion text and destination
- [ ] Every merge shown with proposed final content
- [ ] Every compression shown with verbatim rewrite + line-count delta; conforms to `auto-memory-style.md` length budget
- [ ] Every conflict shows both sources + chosen survivor + supersession stub
- [ ] `MEMORY.md` count matches file count post-run (superseded files counted but not indexed — they live as audit trail)
- [ ] No promotion landed in `skill-optimization.md` unless it's a skill-*authoring* rule (this is the most common mis-routing)
- [ ] Run summary reports compression rate aggregate (`Compressed N entries, total reduction X%`)
- [ ] Audit report archived (if any non-trivial actions taken)
