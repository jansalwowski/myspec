# `/myspec:feature-verify` — examples

Read-only health check across all 8 documentation categories (spec, tech-spec, plan, implementation files, sub-features, memories, manifest, dependencies). Produces a severity-ranked diagnostic report and routes each issue to the correct fix skill. **Never modifies files.**

> **Related**: For the full drift-recovery flow that follows a verify run with multiple issues, see [flows/spec-drift-recovery.md](../flows/spec-drift-recovery.md). The scenarios here focus on the verify skill itself.

**Contents**

- [Clean health check — all green](#clean-health-check--all-green)
- [Mixed report with severity-ranked routing](#mixed-report-with-severity-ranked-routing)

---

## Clean health check — all green

The base case: a feature in good shape after a recent ship. Useful as a pre-merge sanity check or before starting follow-up work.

### Setup

`favorite-reports` shipped two days ago. Spec is at v1 status complete, tech-spec is `complete` and matches code. Plan is archived. The user is about to start a follow-up feature that depends on this and wants to confirm there's no drift.

### Invocation

```
/myspec:feature-verify favorite-reports
```

### Skill flow

The skill walks the 8 categories. Each check passes. Final report:

```
Feature Health: favorite-reports
─────────────────────────────────

[CRITICAL] none
[HIGH]     none
[MEDIUM]   none
[LOW]      none

Summary
─────────
✓ spec.md — frontmatter complete, status approved, v1
✓ tech-spec.md — frontmatter complete, based_on_spec_version aligned (v1)
✓ implementation-plan.md — archived to plans/2026-04-28-favorite-reports.md
  CHANGELOG entry present.
✓ File Inventory — 5 created, 2 modified, all paths exist
✓ Implementation Steps — 6/6 [x], all referenced files present
✓ Sub-features — none (single feature, n/a)
✓ Memory references — 1 procedural memory P016 references this feature, anchor verified
✓ Manifest — index.yaml shows status: complete, phase: 1, no drift

Feature is healthy. Safe to depend on.
```

### Result

No files modified. Report printed to the conversation.

### Why this example matters

- **A clean report is a real outcome, not a placeholder.** "Safe to depend on" is the message a downstream feature author needs before referencing types or endpoints from this feature.
- **The 8 categories are exhaustive.** A feature can be passing tests but failing memory-anchor verification (a memory points at a file that's since moved) — verify catches that. Tests can't.
- **Read-only is load-bearing.** A user can verify someone else's feature without risk. They can verify a feature in a worktree without disturbing the main checkout. The skill's restraint is what makes it safe to run liberally.

---

## Mixed report with severity-ranked routing

The interesting case: a feature with mid-severity issues. The report routes each issue to its corresponding fix skill so the user knows exactly what to run next.

### Setup

`team-invites` is at `spec_version: 2` after the bulk-invite update was implemented and shipped. Two months later, the user is opening it back up to add SSO auto-invite (covered in [feature-update.md](feature-update.md)). Before starting, they run verify to see what shape the docs are in.

### Invocation

```
/myspec:feature-verify team-invites
```

### Skill flow

The skill walks the categories and produces:

```
Feature Health: team-invites
─────────────────────────────

[CRITICAL] none

[HIGH]
  ✗ tech-spec.md File Inventory references 2 paths that no longer exist:
    - src/services/invite-magic-link.ts (deleted in v3 — magic-link deprecation)
    - src/components/MagicLinkButton.tsx (deleted in v3)
    Both files were removed during the deprecation work, but tech-spec
    File Inventory still lists them with Action: Delete (not removed
    from the inventory after deletion completed).

  ✗ Implementation Steps: 1 unchecked [ ] step that describes work that
    appears done in the codebase ("Remove magic-link UI, endpoint, service
    method, and related tests" — files all gone, OpenAPI regenerated).
    Should be checked.

[MEDIUM]
  ⚠ scenarios.md last updated 2026-02. Bulk-invite (US7, US8) and
    magic-link deprecation are not represented in scenarios.

  ⚠ Memory anchor stale: procedural memory P022 ("admin-only routes use
    requireAdmin middleware") anchors to src/middleware/require-admin.ts
    line pattern "requireAdmin". File exists but the function was renamed
    to `requireAdminRole` two weeks ago. Memory will mis-match on lookup.

[LOW]
  ⚠ index.yaml entry: phase: 2 (bumped during bulk-invite). Now that
    magic-link is also deprecated, consider phase: 3 to reflect the
    architecture changes.

Recommended sequence
─────────────────────
1. /myspec:feature-spec-sync team-invites
   — fixes both [HIGH] items (file inventory + implementation step
     reconciliation)
2. /myspec:feature-scenario team-invites
   — regenerate scenarios for US7, US8, and the magic-link removal
3. Update memory P022 manually (rename anchor pattern to
   `requireAdminRole`) or run /myspec:memory-create to replace
4. Optional: bump index.yaml phase to 3 if you want strict alignment
5. Re-run /myspec:feature-verify team-invites to confirm
```

### Result

No files modified. Five concrete next steps. The user runs them sequentially over the next ~20 minutes; the second `feature-verify` run comes back clean.

### Why this example matters

- **Severity is not noise — it changes order of operations.** [HIGH] items block downstream skills (a stale tech-spec File Inventory will mislead `feature-plan` next). [MEDIUM] and [LOW] are quality-of-life, fixable later if needed.
- **The "Recommended sequence" is the actual product.** Verify is a router as much as a checker. A user who reads only the recommendations and runs them in order will get a clean feature; the rest of the report is justification for why each step is on the list.
- **Memory-anchor staleness is one of the rarest and most useful checks.** A renamed function silently invalidates pinned procedural memories. No other skill catches this — you have to be looking at memories *and* current code to notice.
- **Verify is the entry point for drift recovery.** When the report is bigger than this one, it's the same skill — see [flows/spec-drift-recovery.md](../flows/spec-drift-recovery.md) for an example with critical-severity drift.
