---
name: "memory-sanitize"
description: "Use when sanitizing the user-level auto-memory store: triage entries, drop stale/trivial/duplicate, promote feedback to CLAUDE.md or .claude/rules/, merge clusters. Keywords: sanitize memory, audit memory, prune memories, memory triage, memory health. Do NOT use for project ai/memory/ (myspec system), creating memories (/myspec:memory-create), or searching memories (/myspec:memory-lookup)."
---

# Memory Sanitize

Audit the user-level auto-memory store for this project, triage each entry, and execute drops/promotions/merges with explicit confirmation.

**Critical constraints:** never auto-promote (always show destination + exact insertion text); never delete a still-cited memory (grep first); skip entries <7 days old; do not touch project `ai/memory/`. See [Hard guards](#hard-guards) for full set.

## Scope

- **In scope:** `~/.claude-personal/projects/{encoded-cwd}/memory/` (user-level auto-memory). The encoded cwd is the absolute project path with `/` and `_` both replaced by `-` (e.g. `/Users/jane/public_html/foo` → `-Users-jane-public-html-foo`).
- **Out of scope:** project `ai/memory/{procedural,semantic,episodic}/` (myspec system).

## Workflow

### Phase 1 — Inventory

1. Resolve memory dir: `~/.claude-personal/projects/$(pwd | tr '/_' '-')/memory/`. Refuse if missing.
2. Read `MEMORY.md` and every `*.md` entry it links to.
3. Integrity check: list orphans (files not in `MEMORY.md`) and broken links (entries pointing to missing files). Report both.

### Phase 2 — Per-entry triage

For each memory, run cheap verifications and assign ONE bucket:

| Bucket | Trigger |
|---|---|
| **KEEP** | Claim still accurate, non-obvious, project-specific |
| **DROP-stale** | Cited file/symbol/dep no longer exists or contradicts current code |
| **DROP-trivial** | True but generic enough that any reasonable agent does it anyway |
| **DROP-duplicate** | Strongly overlaps another memory or a `.claude/rules/` file |
| **PROMOTE** | Belongs in CLAUDE.md, `.claude/rules/{X}.md`, or a specific `.claude/skills/{X}/SKILL.md` body |
| **MERGE** | Fires in the same scenario as ≥1 other memory (defer to Phase 3) |

**Cheap verifications:**
- File paths cited → check exists
- Specific symbols/functions → grep once
- Dep version claims → check `package.json` or relevant config
- Skip deep semantic verification — flag for human review instead

**Skip files modified <7 days ago.** Recent memories haven't earned skepticism yet.

### Phase 3 — Cluster pass

Over the KEEP+PROMOTE set, group by trigger scenario (e.g. "fresh worktree onboarding", "Stop hook misfires", "OOM during build"). Any cluster of ≥2 → propose MERGE into one consolidated file.

### Phase 4 — Report

Print one table grouped by bucket. For DROP entries: one-line reason. For PROMOTE: candidate destination file + section. For MERGE: cluster name + member files.

### Phase 5 — Confirm and execute

**Drops (low-risk, batch):** one confirmation for all drops.
- Before deleting: `grep -r {filename}` across the repo. If any active doc/spec/rule still cites the memory, refuse the drop and reclassify as KEEP.

**Promotions (medium-risk, individual):** for each, show:
- Source memory full text
- Destination file + insertion location (which section, after which line)
- Exact text to be inserted (verbatim, not "I will summarize…")
- Then ask to apply

**Merges (medium-risk, individual):** for each cluster, show:
- Proposed merged-file path + content
- List of source files to delete
- Then ask to apply

Use the AskUserQuestion tool for confirmations (one prompt per group/promotion/merge).

### Phase 6 — Update index and verify

After every executed action:
1. Update `MEMORY.md` (remove dropped/merged entries, update merge survivors)
2. Verify: `grep -c '^- \[' MEMORY.md` matches `ls memory/ | grep -v MEMORY.md | wc -l`
3. Optional: archive the triage report to `~/.claude-personal/projects/{encoded-cwd}/memory/audit-{YYYY-MM-DD}.md`

## Hard guards

- **Never auto-promote.** Destination + exact insertion text shown before each promotion.
- **Never delete a still-cited memory.** Grep across `ai/`, `.claude/`, `apps/`, `packages/` before any rm.
- **MEMORY.md edits are atomic with file deletes.** Never leave the index out of sync.
- **Don't sanitize entries <7 days old.**
- **Don't touch the project's `ai/memory/`.** Separate system, separate skill.

## Promotion routing reference

| Memory pattern | Destination |
|---|---|
| Output style / response formatting | `CLAUDE.md` Core Principles |
| Tool selection (e.g. AskUserQuestion preference) | `CLAUDE.md` Core Principles |
| Workflow phase behavior (e.g. suggest next skill) | `.claude/rules/workflow.md` |
| Backend-specific pattern | `.claude/rules/backend.md` |
| Frontend-specific pattern | `.claude/rules/frontend.md` |
| Lint/TS rule | `.claude/rules/lint-and-types.md` |
| Skill prerequisite or workflow constraint | `.claude/skills/{name}/SKILL.md` body |
| Skill-authoring meta-rule | `.claude/rules/skill-optimization.md` |

If the destination is ambiguous, leave as KEEP and flag in the report.

## Verification checklist

```bash
# After execution:
grep -c '^- \[' "$MEM_DIR/MEMORY.md"        # entry count
ls "$MEM_DIR" | grep -v MEMORY.md | wc -l    # file count — must match
```

- [ ] Every drop preceded by repo-wide grep for live citations
- [ ] Every promotion shown with verbatim insertion text and destination
- [ ] Every merge shown with proposed final content
- [ ] `MEMORY.md` count matches file count post-run
- [ ] No promotion landed in `skill-optimization.md` unless it's a skill-*authoring* rule (this is the most common mis-routing)
- [ ] Audit report archived (if any non-trivial actions taken)
