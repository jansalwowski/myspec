# `/myspec:feature-complete` — examples

Marks a feature as shipped: syncs `tech-spec.md` to reality, updates the manifest, archives the implementation plan, updates the CHANGELOG, and offers branch integration. Runs after `feature-implement` is done and (ideally) `feature-verify` is green.

**Contents**

- [Clean completion](#clean-completion) — straightforward end-of-feature wrap-up
- [Discovers late drift during completion](#discovers-late-drift-during-completion) — the skill detects mismatch and routes to spec-sync mid-flow

---

## Clean completion

The standard path: implementation finished, verify is green, the user runs complete to flip status and archive.

### Setup

`favorite-reports` finished `feature-implement`. All 6 plan tasks `[x]`. The user ran `/feature-verify favorite-reports` — clean report. Now wrapping up.

### Invocation

```
/myspec:feature-complete favorite-reports
```

### Skill flow

#### Phase 1 — Docs sync

1. **Read current state**: loads `tech-spec.md` (v1, status: draft because it's been waiting on completion), `spec.md` (v1, approved), manifest entry (`status: in-progress, phase: 1`).
2. **Validate Implementation Steps**: all 6 steps already `[x]` from feature-implement's phase reviews. No changes.
3. **Update File Inventory**: cross-checks planned vs. actual. One file ended up in a different sub-directory than planned (`src/features/reports/favorites/sort.ts` vs. planned `src/features/reports/sort-favorites.ts`). Skill prompts:

   > File Inventory drift:
   >
   > - Planned: `src/features/reports/sort-favorites.ts`
   > - Actual: `src/features/reports/favorites/sort.ts`
   >
   > Update the inventory to match the actual path?

   User confirms; the inventory row is updated.

4. **Document decisions made**: scans the diff for any unrecorded design choices. Finds one — the StarButton uses optimistic UI updates rather than waiting on the API response. Skill prompts:

   > I see the StarButton implementation uses optimistic updates. Should I add an ADR to capture this?

   User: yes. ADR-2 added: *"StarButton uses optimistic UI for star/unstar."* Context: instant feedback on a low-stakes mutation; rollback on API error.

5. **Update frontmatter**: `tech-spec.md` `last_updated: 2026-04-30`, `status: complete`. `based_on_spec_version: 1` already aligned.

6. **Update Feature Manifest**: edits `ai/features/index.yaml`:

   ```yaml
   - name: favorite-reports
     title: "Favorite Reports"
     status: complete       # was in-progress
     phase: 1
     priority: P2
     depends-on: []
   ```

7. **Archive implementation plan**: moves `implementation-plan.md` → `plans/2026-04-30-favorite-reports.md`. Adds `archived: 2026-04-30` to its frontmatter.

   Creates `CHANGELOG.md`:

   ```markdown
   # Favorite Reports Changelog

   | Date | Plan | Summary | Status |
   |------|------|---------|--------|
   | 2026-04-30 | [Favorite Reports — Implementation Plan](plans/2026-04-30-favorite-reports.md) | End-to-end favoriting: schema, service, API, hook, UI, sort. | complete |
   ```

8. **Cross-reference check**: `dependencies.md` has no upstream dependencies, no downstream features yet. Nothing to update.

The skill reports:

> Phase 1 complete. Documentation synced. Plan archived.

#### Phase 2 — Branch integration

The skill checks `git status`:

```
On branch feature/favorite-reports
Your branch is ahead of 'origin/main' by 7 commits.
Working tree clean.
```

Asks:

> Branch integration:
>
> - **A) Open a PR** — I'll run `gh pr create` with a generated title + body summarizing the changes.
> - **B) Merge to main** — local merge. Use this if you don't use PRs for this kind of feature.
> - **C) Skip** — I'll leave the branch as-is and you'll handle integration manually.

User: A.

The skill runs:

```bash
gh pr create --title "feat: favorite reports" --body "$(cat <<'EOF'
## Summary
Adds a "favorite reports" capability — users star reports to pin them
to the top of their list.

## Changes
- New `report_favorites` table
- `ReportFavoritesService` with add/remove/list/isFavorite
- `POST /api/reports/:id/favorite` and `DELETE /api/reports/:id/favorite`
- `useReportFavorites` hook
- `StarButton` in ReportListRow (optimistic UI)
- Pin-to-top sort in the list query

## Test plan
- [x] Unit tests pass (service, hook)
- [x] API tests pass (handlers)
- [x] E2E test passes (favorite → unfavorite → list order)
- [ ] Manual: star a report, refresh, confirm pinning persists

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Returns the PR URL.

### Result

- `tech-spec.md` status flipped to `complete`, ADR-2 added, file path corrected.
- Manifest status flipped to `complete`.
- `implementation-plan.md` moved to `plans/2026-04-30-favorite-reports.md`.
- `CHANGELOG.md` created with one row.
- PR opened with auto-generated description.

### Why this example matters

- **Completion is mostly bookkeeping, but the bookkeeping matters.** The CHANGELOG entry is what a future agent finds when they run `feature-verify` next year — without it, they have no record of what shipped when.
- **The skill detects undocumented decisions.** Optimistic UI for star/unstar is a small choice but a real one — capturing it as ADR-2 means the next person doesn't ripip out the optimism thinking it was an oversight.
- **File path drift is normal during implementation** and the skill expects it. Reconciling the inventory at completion (rather than fighting drift in real-time) is the right trade-off.
- **Branch integration is opt-in per call.** Users who want to do PRs by hand pick C; users on solo features pick B; teams with PR review pick A. The skill doesn't enforce a workflow — it offers options.

---

## Discovers late drift during completion

Sometimes verify wasn't run, or it was run too early, and the completion phase exposes drift. The skill detects, reports, and routes — it doesn't try to silently paper over the gaps.

### Setup

`scheduled-reports` finished `feature-implement` last week. The dev tested locally, didn't run `feature-verify`, and is wrapping up now. In the intervening days they made one "small" hotfix on the feature branch — added a retry-on-503 to the email sender — without updating tech-spec.

### Invocation

```
/myspec:feature-complete scheduled-reports
```

### Skill flow

#### Phase 1 — Docs sync

1. **Read current state**: tech-spec.md `based_on_spec_version: 2`, status `draft`, 11 implementation steps all `[x]`.
2. **Validate Implementation Steps**: all 11 `[x]` ✓.
3. **Update File Inventory**: scans planned vs. actual. Finds drift:

   ```
   File Inventory reconciliation:

   Planned, exists ✓ (no change):  9 files
   Planned, exists ✓ (path drift): 0 files

   In codebase, NOT in inventory:
   - src/features/scheduled-reports/email-retry.ts          (123 lines, recent)
   - src/features/scheduled-reports/__tests__/email-retry.test.ts (recent)

   This looks like work done outside the implementation plan. Two
   possibilities:

   - It was a small fix that should be folded into the existing tech-spec
     (add to File Inventory, mention in Architecture/Implementation Steps).
   - It was significant enough to warrant a feature-update bump (changes
     reliability behavior, may affect SLAs documented in spec).

   How should I handle it?
   ```

   The skill paused here — it's not going to invent inventory rows or fabricate ADRs.

   User explains: it's a 503-retry shim, ~30 lines of real logic + tests, behavior is "retry up to 3 times with backoff on transient SMTP 5xx." This adjusts the failure-handling ADR (ADR-3 in tech-spec).

   The skill responds:

   > That's borderline — the behavior change tightens the existing failure-handling ADR rather than adding a new capability. I can fold it in here, but it'll require:
   >
   > - Adding 2 files to File Inventory (Action: Create)
   > - Updating ADR-3's "Decision" to mention the 503-retry behavior explicitly
   > - Adding 1 implementation step (already done — will be marked [x])
   > - Bumping `tech-spec.md` `last_updated`
   >
   > spec.md doesn't need a change — the user-visible behavior is the same.
   >
   > Alternatively, if you'd rather track this as its own delta (cleaner audit trail), I can stop here and you can run `/myspec:feature-update scheduled-reports` to bump spec_version and tech-spec accordingly.

   User picks "fold it in" (the change is small enough that a separate update would be ceremony).

4. **Document decisions made**: ADR-3 updated. The 503-retry policy is appended to the Decision text with a note "(refined during implementation, see commit abc123)."

5. **Update frontmatter**: `tech-spec.md` `last_updated: 2026-04-30`, status flipped to `complete`.

6. **Update Feature Manifest**: status `complete`, phase 2.

7. **Archive plan**: moves to `plans/2026-04-30-scheduled-reports-v1.md`. CHANGELOG row notes the late inclusion: "Folded in 503-retry shim during completion (see ADR-3)."

8. **Cross-reference check**: `notification-system/dependencies.md` lists `scheduled-reports` as dependent — no change needed since the contract is unchanged.

#### Phase 2 — Branch integration

Standard PR flow.

### Result

- Tech-spec File Inventory updated (+2 files).
- ADR-3 refined to capture the 503-retry behavior.
- Plan archived; CHANGELOG row notes the late inclusion.
- PR opened.

The skill ends with:

> Completion done. **Recommendation**: next time, run `/myspec:feature-verify scheduled-reports` before `/myspec:feature-complete` — verify would have caught the inventory mismatch earlier and given you a chance to handle it cleanly. The fix here was small, but for larger drifts the right path is `/myspec:feature-update` first.

### Why this example matters

- **The skill won't silently fabricate.** It detects the inventory drift and asks the user to classify the missing files. This is the difference between completion-as-bookkeeping and completion-as-rubber-stamp.
- **Decision-tier prompts are real.** "Fold it in" vs. "treat as a feature-update" is a judgment call about audit-trail granularity. The skill explains the consequences and lets the user choose.
- **Late-stage ADR refinement is a normal pattern.** Fixes during implementation often refine an existing decision rather than introducing a new one — the skill handles "amend ADR-3" cleanly.
- **The trailing recommendation is non-judgmental.** No "you should have..." — just a note about what would have caught this earlier. Useful for next time, no lecture.
