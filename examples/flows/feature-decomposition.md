# Flow — feature decomposition (split → parallel sub-feature delivery)

A feature got too big to fit in one tech-spec. This flow shows how to split it into sub-features and ship them independently — each with its own spec, tech-spec, plan, and implementation.

## The situation

A feature called **`search`** has been sitting at `status: draft` for two weeks. The spec accumulated requirements as users requested more capability:

- Full-text search across reports
- Faceted filters (date range, owner, tag)
- "Trending searches" panel on the dashboard
- Saved searches
- Search-from-anywhere keyboard shortcut

Five distinct capabilities, ~30 acceptance criteria, ~12 user stories. The team realizes a single tech-spec/plan would balloon past the 20-task ceiling. Time to decompose.

## At a glance

| Step | Skill | What happens |
|------|-------|--------------|
| 1 | `/myspec:feature-decompose search` | Analyzes spec, proposes 3 sub-features, creates directories |
| 2 | (per sub-feature) `/myspec:feature-tech-spec` | Each sub-feature gets its own design |
| 3 | `/myspec:cross-spec-validation` | Catches contracts between sub-features |
| 4 | (per sub-feature) `/myspec:feature-plan` | Each gets its own milestone-based plan |
| 5 | `/myspec:feature-implement` | Sub-features ship independently or in priority order |
| 6 | `/myspec:feature-complete` | Per sub-feature; parent stays open until all complete |

---

## 1. Decompose — propose the split

```
/myspec:feature-decompose search
```

The agent reads `spec.md`, finds the cluster signals (5 capability headings, mostly disjoint user stories), and proposes:

```markdown
## Proposed Sub-Features for `search`

### Sub-Feature 1: search-core
- **Status**: draft
- **Priority**: P1
- **Description**: Full-text search across reports with a results page.
- **Content from parent**:
  - User stories: US1, US2
  - Requirements: REQ1, REQ2, REQ3
  - Scenarios: S1, S2

### Sub-Feature 2: search-filters
- **Status**: draft
- **Priority**: P2
- **Description**: Faceted filters (date, owner, tag) layered onto search-core results.
- **Depends on**: search-core
- **Content from parent**:
  - User stories: US3, US4
  - Requirements: REQ4, REQ5, REQ6, REQ7
  - Scenarios: S3, S4, S5

### Sub-Feature 3: search-trending
- **Status**: draft
- **Priority**: P3
- **Description**: "Trending searches" panel on dashboard, surfaces top queries from last 7 days.
- **Depends on**: search-core (analytics events)
- **Content from parent**:
  - User stories: US5
  - Requirements: REQ8, REQ9
  - Scenarios: S6

### Deferred (not yet split out)
- Saved searches → punt to a future sub-feature, capture in ideas/.
- Search-from-anywhere shortcut → punt; UX still being designed.

### Parent Feature Changes
- `search/spec.md` becomes the umbrella: status `in-progress`, removes the per-capability detail (now in sub-feature specs), gains a Sub-Features table.
- `search/tech-spec.md` is deleted (was draft, never approved).
```

**User confirms the split**, asks to bump `search-trending` to P2 since the marketing team wants it for a campaign.

The agent:
- Creates `ai/features/search/{search-core,search-filters,search-trending}/`, each with `spec.md` populated from the parent's relevant content.
- Creates `ai/features/search/index.yaml` listing the three sub-features.
- Rewrites the parent `ai/features/search/spec.md` as an umbrella doc with a Sub-Features table.
- Updates `ai/features/index.yaml`: parent `search` is now `status: in-progress` and references its index.yaml.
- Files the deferred items as `ideas/search-saved.md` and `ideas/search-shortcut.md` (each a one-liner pointing back at the parent).

---

## 2. Per-sub-feature tech-specs (parallel-friendly)

The user runs three tech-spec sessions, **possibly in different terminals or different days**:

```
/myspec:feature-tech-spec search/search-core
/myspec:feature-tech-spec search/search-filters
/myspec:feature-tech-spec search/search-trending
```

Each session is independent. The path includes the parent slug (`search/...`) so the skill knows it's working on a sub-feature. Each gets its own `tech-spec.md`:

- **search-core/tech-spec.md** — Postgres `tsvector` index, search service, results page. ~8 implementation steps.
- **search-filters/tech-spec.md** — query-param-driven filter UI, narrows search-core results via additional `WHERE` clauses. ~6 steps. Uses interfaces defined in search-core.
- **search-trending/tech-spec.md** — analytics event consumer, trending query store (Redis sorted set with 7-day TTL), dashboard panel. ~7 steps. Reads search analytics emitted by search-core.

---

## 3. Cross-spec validation — catch the inter-sub-feature contracts

```
/myspec:cross-spec-validation search/search-filters
/myspec:cross-spec-validation search/search-trending
```

Both sub-features depend on contracts owned by `search-core`. The validation surfaces:

- **search-filters** assumes `SearchService.query(input: SearchInput)` accepts a `filters` object — but `search-core/tech-spec.md` defines `SearchInput` without that field.
- **search-trending** assumes search-core emits a `search.executed` analytics event — but search-core's tech-spec only logs queries to a table.

Both gaps are real. The user updates `search-core/tech-spec.md`:

- Extends `SearchInput` with an optional `filters: SearchFilters` field.
- Adds an analytics-event emission step.

Re-runs cross-spec-validation on each dependent — green.

---

## 4. Per-sub-feature plans

```
/myspec:feature-plan search/search-core
```

Produces `ai/features/search/search-core/implementation-plan.md` — a single milestone (~8 tasks, mostly sequential because the search index is a barrier). Approved.

```
/myspec:feature-plan search/search-filters
/myspec:feature-plan search/search-trending
```

Two more plans, **both gated on `search-core`** completing first. Each plan's first phase has `Depends On: search-core (sub-feature complete)`.

---

## 5. Implement — sequential by dependency, parallel where safe

```
/myspec:feature-implement search/search-core
```

Runs to completion. Search-core ships behind a feature flag. **User merges and deploys.**

Now `search-filters` and `search-trending` are unblocked and **share no files** with each other (filters touches the results page; trending touches the dashboard). The user can:

**Option A — sequential**:
```
/myspec:feature-implement search/search-filters
# ...wait for completion, merge...
/myspec:feature-implement search/search-trending
```

**Option B — two parallel work streams** (different agents, different worktrees, different PRs):

In agent 1:
```
/myspec:feature-implement search/search-filters
```

In agent 2 (separate session, separate worktree):
```
/myspec:feature-implement search/search-trending
```

Because the sub-feature plans target disjoint files, the two streams never collide. Each agent runs its own milestones, opens its own PR.

---

## 6. Per-sub-feature completion — and the umbrella

After search-core ships:

```
/myspec:feature-complete search/search-core
```

Updates `search-core` status to `complete` in `ai/features/search/index.yaml`. **The parent `search` feature stays `in-progress`** — the umbrella is only `complete` once all sub-features are.

After search-filters and search-trending also ship:

```
/myspec:feature-complete search/search-filters
/myspec:feature-complete search/search-trending
```

At that point, the agent notices the parent has no remaining `in-progress` or `draft` sub-features and asks:

> All sub-features under `search` are complete. Mark the parent `search` feature as complete too?

**User**: yes. Parent flips to `complete`, the deferred ideas remain in `ideas/` for future work.

---

## What this flow demonstrates

- **Decomposition is a turning point, not just a refactor.** Once the spec is split, every downstream skill (tech-spec, plan, implement, complete) operates on the sub-feature, not the parent.
- **Sub-feature paths use `parent/sub` everywhere.** The feature-* skills understand this convention; you don't need to flatten names.
- **Cross-spec-validation is mandatory after decomposition.** Sub-features inherit content from a single source — but their tech-specs evolve independently and *will* drift on shared interfaces. Run validation early, often.
- **Independent sub-features unlock real parallelism across agents**, not just within one plan. Worktree isolation makes this safe.
- **The umbrella's `complete` is gated on all children.** This prevents the common bug of "we forgot search-trending" sneaking past.

---

## When NOT to decompose

- The feature has < 6 implementation steps total — you'll add ceremony without saving complexity.
- The "capabilities" share most of their files — splitting will just mean three sub-features all editing `searchService.ts`, which kills the parallelism benefit.
- The team is one person and the feature ships in a day. Decomposition pays off when work crosses sessions, agents, or weeks.
