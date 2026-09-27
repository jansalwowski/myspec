---
name: feature-tech-spec-review
description: "Use when a tech-spec.md needs review for implementability, spec alignment, and pattern conformance before planning. Keywords: validate technical design, critique tech-spec. Do NOT use for spec.md (feature-spec-review) or code (code-review)."
tags: [feature, tech-spec, validation, critical-thinking, review]
---

# Feature Tech-Spec Review

**Autopilot:** when the user opted in, answer this skill's gates per [`_shared/autopilot.md`](../_shared/autopilot.md).

## Workflow

1. **Load Context**
   - Read `${aiDir}/features/{feature}/tech-spec.md`
   - Read `${aiDir}/features/{feature}/spec.md`
   - Read `${aiDir}/features/{feature}/dependencies.md`
   - Read `${aiDir}/features/index.yaml` to verify feature status
   - Read `.claude/rules/` convention files if they exist (backend, frontend, database)
   - If sub-feature: also read parent tech-spec.md

2. **Analyze Structure**
   - Verify required sections exist: Architecture, Reuse audit, Implementation Steps, Edge Cases, File Inventory
   - Check optional sections present if relevant: Key Interfaces/Types, Database Changes, API Schema, API Endpoints, Decisions
   - **Reuse-audit gate** (skip only if `.myspec.json` has `reuseAudit.enabled: false`). Flag and **refuse approval** (do not recommend `/myspec:feature-plan`) when the `### Reuse audit` section is:
     - missing, OR
     - an empty table (header + separator only, zero data rows), OR
     - a blanket-skip audit (every row `skip`) with one or more rows lacking a `Reason`, OR
     - has any `skip` row with an empty / dash-only `Reason`, OR
     - has any row whose `Decision` is not exactly `reuse` or `skip`.
   - A blanket-skip audit where every row has a substantive `Reason` is allowed but warrants a High finding asking the author to re-confirm nothing is reusable.
   - **Verification-surface gate** (skip when frontmatter has no `verification_mode`, or it is `none`). `verification_mode` must be one of `visual`, `api`, `data`, `mixed`, `none`. Otherwise the `### Test Hooks` section must exist with *Target* and *Contract surface* lines, plus *Scratch environment* when the mode is `visual` or `mixed` (feature-plan adds a `[demo]` probe there), when *Real inputs* is named (a `[real-input]` probe follows), or when the spec's flows mutate data. Probes do not exist yet at this stage, so decide from the mode and the Test Hooks lines, not from probes. Each missing line is High and blocks `/myspec:feature-plan`: `feature-plan` writes checkpoint probes only against these handles. A *Contract surface* entry that reaches past the public surface — a style class, internal element structure, private state — is High, naming the unstable reference.
   - Validate frontmatter has `title`, `status`, `based_on_spec_version`, `created`, `last_updated`
   - Verify `based_on_spec_version` matches current `spec_version` in spec.md

3. **Apply Review Dimensions** (Check tech-spec.md against all 10 dimensions below)
   - Spec Alignment: Every spec.md requirement ID maps to an implementation step (Requirement Coverage table); no orphan tech-spec items without spec backing
   - Feasibility: Implementation steps achievable with the project's tech stack (from `.myspec.json` or CLAUDE.md)
   - Completeness: Missing sections, empty checklists, no file inventory, no edge cases, TBD/TODO present
   - Pattern Conformance: Follows codebase patterns per backend.md, frontend.md, database.md
   - Step Granularity: Steps not too coarse (multi-day, multi-concern) or too fine (single-line changes)
   - Dependency Ordering: Steps in logical order; dependencies created before consumers
   - Testability: Each step verifiable, test files present in file inventory
   - Task-extractability: Each step concrete enough that `feature-plan` can extract a task block without interpretation; vague steps are gap predictors (see Task-Extractability section)
   - YAGNI / Over-Engineering: No unnecessary abstractions, premature optimization, "future-proof" scope
   - Scope / Size Assessment: Judgment-based split detection (see Scope Assessment section)

4. **Cross-Validate Spec Alignment**
   - Build the Requirement Coverage table (see [Requirement Coverage](#requirement-coverage)): one row per spec.md requirement ID, mapped to implementation step(s) with a Fidelity verdict. Every row with no step is a Critical finding; a step that narrows the requirement is High, one that contradicts it Critical
   - Check: Every acceptance criterion in spec.md is traceable to a file in the inventory or a step
   - Check: No implementation step introduces functionality not in spec.md (scope creep)
   - Check: `based_on_spec_version` matches spec.md `spec_version` — mismatch is Critical

5. **Check Pattern Conformance**
   - Check: Implementation follows patterns defined in `${aiDir}/conventions/` and `.claude/rules/`
   - Check: File paths match expected project organization (per conventions docs)
   - Check: Naming conventions followed (per project coding standards)
   - Check: Database models include required audit fields (per project database conventions, if defined)
   - Check: Service/component patterns match project conventions (per project rules, if defined)

6. **Present Findings**
   - Output table: Severity | Dimension | Issue | File | Line(s) | Finding
   - Group by severity: Critical → High → Medium → Low
   - Include specific line numbers for each issue

7. **Classify and Apply Fixes**
   - **Small issues** (typos, missing sections, unclear wording, missing edge cases, frontmatter fixes): apply immediately without asking
   - **Big issues** (strategy changes, splitting into sub-features, removing/changing steps, interface changes, conceptual problems): propose solution and WAIT for confirmation
   - Tag proposals: `[auto-fix]` or `[requires confirmation]`
   - Use diff format: `- old text` / `+ new text`

8. **Execute Changes**
   - Apply small fixes immediately
   - Apply confirmed big fixes
   - Update `last_updated` date in frontmatter
   - If `based_on_spec_version` was stale but spec is unchanged: update it

9. **Approve & Summary**
   - Show changes made (file paths, sections affected)
   - List remaining issues (if any were rejected)
   - If no Critical/High remain, ask: "Review passed — mark tech-spec.md `status: approved`?" On yes, set `status: approved` in tech-spec.md frontmatter — the transition `feature-plan` gates on (see the Status State Machine in `.claude/rules/workflow.md`). Otherwise it stays `draft`.
   - Recommend next step: re-review, `/myspec:feature-plan`, or address open issues first

## Review Dimensions Reference

| Dimension | Detection Patterns | What to Check |
|-----------|-------------------|---------------|
| **Spec Alignment** | Requirement Coverage table has an empty Steps cell or a `narrows`/`contradicts` Fidelity cell; step with no spec backing | Every requirement ID maps to a step, no orphan steps, version match |
| **Feasibility** | Unknown packages, non-existent APIs, impossible constraints | Steps achievable with the project's tech stack |
| **Completeness** | `TBD`, `TODO`, `???`, empty sections, missing file inventory | All required sections present, all steps have detail |
| **Pattern Conformance** | Service/GraphQL/validator/component patterns | Matches backend.md, frontend.md, database.md conventions |
| **Step Granularity** | Steps joining unrelated work with "and", single-line steps | Each step = single responsibility, ~1–4 hours |
| **Dependency Ordering** | Step N references types/files from Step N+M | Steps ordered so dependencies created before consumers |
| **Testability** | Steps without test files in inventory, no test strategy | Each step has verifiable output, test file in inventory |
| **Task-extractability** | Steps phrased as outcomes/intents ("handle errors", "add validation") with no named files, contracts, or concrete behavior | Each step is concrete enough to become a plan task without interpretation (see Task-Extractability section) |
| **YAGNI** | `future`, `extensible`, `scalable`, `flexible`, generic abstractions | No unused abstractions, no premature optimization |
| **Scope / Size** | Multiple independent capabilities, unrelated domains mixed | See Scope Assessment section |

## Scope Assessment

This dimension is **judgment-based**, not threshold-based. Do NOT count steps or lines. Look for these signals:

| Signal | Indicates Split Needed |
|--------|----------------------|
| Multiple independent capabilities that could ship separately | Yes |
| Unrelated domain areas mixed in one tech-spec | Yes |
| Steps with zero dependency on each other serving different user stories | Likely |
| Feature touches multiple unrelated areas of the codebase | Likely |
| "Phase 2" or "deferred" sections with substantial scope | Consider sub-feature |
| Single coherent capability with many steps | No — large is fine if cohesive |

When splitting is recommended:
- Propose concrete sub-feature boundaries with names
- Reference `/myspec:feature-decompose` skill for execution
- Flag as High severity (tech-spec is valid but should be restructured)

## Requirement Coverage

Build this table by walking `spec.md`, not the tech-spec — reading the steps and asking what they cover finds only what is already there. One row per requirement, in source order, using the IDs spec.md assigns (`REQ-001`, `NFR-2`; unprefixed numbering → `R<n>`). A requirement gets its own row even when an AC restates it.

```markdown
| Requirement | Steps | Fidelity |
|-------------|-------|----------|
| REQ-001 | 2, 5 | full |
| REQ-002 | — | — |
| REQ-003 | 4 | narrows — step 4 filters by owner only; REQ-003 also covers shared reports |
| NFR-1 | Out of scope — spec.md §Out of Scope lists offline mode | — |
```

- A row cites the step(s) that realize the requirement's behavior, not steps that merely share its vocabulary or files.
- Fidelity: read the cited steps against the requirement's text, and against any requirement a step itself cites. `narrows` (drops a case, input, actor, or condition the requirement states) is a **High** Spec Alignment finding; `contradicts` is **Critical**. Quote both passages in the finding.
- An empty (`—`) Steps cell is a **Critical** Spec Alignment finding (missing core implementation path); quote the requirement in the finding.
- A requirement may be marked out of scope only when spec.md itself excludes it; the reason cites that passage. The reviewer never decides a requirement is out of scope.
- Include the table in the review output so the author and `feature-plan` can check it.

## Task-Extractability

This dimension catches the spec→plan translation gap: `feature-plan` turns each implementation step into a task block that a worker executes **verbatim, without reading the tech-spec**. Any requirement a step leaves implicit becomes invisible downstream. The reviewer's job here is to make sure each step carries enough concrete detail that a plan task can be extracted from it without interpretation.

This is **judgment-based**, not a keyword count. A step is a gap predictor when a competent plan author would have to *guess* to turn it into a task. Signals:

| Signal | Indicates Gap Predictor |
|--------|-------------------------|
| Step states an outcome but not the mechanism ("handle errors", "add validation", "wire up the API") | Yes |
| Step names no file, function, endpoint, or data shape it touches | Likely |
| Step references a spec AC by intent but not the observable behavior that satisfies it ("fail gracefully") | Yes |
| Step defers detail to "as appropriate" / "if needed" / "etc." | Yes |
| Step is concrete on the happy path but silent on the error/edge behavior the spec requires | Likely |

When flagging:
- **Medium severity** by default — the tech-spec is valid but will leak a requirement at plan time.
- Quote the vague step and name the missing concretion (which file, which behavior, which contract), so the author can tighten it before `feature-plan` runs.
- Stay **medium-agnostic**: do not prescribe a language, framework, or test tool — "concrete" means the *what and where* are pinned down, not that any particular stack is named.

## Fix Policy

| Category | Examples | Action |
|----------|----------|--------|
| **Small (auto-fix)** | Typos, missing edge cases, frontmatter date fixes, adding missing sections with stub content, unclear wording, missing file inventory rows | Apply immediately |
| **Big (requires confirmation)** | Strategy changes, splitting into sub-features, removing or reordering steps, adding new capabilities, changing interfaces, conceptual issues | Propose and WAIT |

## Detection Patterns (Automated Checks)

```typescript
// Incomplete content (Completeness)
/\b(TBD|TODO|FIXME|\?\?\?|placeholder)\b/gi

// YAGNI indicators
/\b(future[- ]proof|extensible|scalable|flexible|generic|just in case)\b/gi

// Missing checklist items (Completeness)
// Check: Implementation Steps section has at least one `- [ ]` item

// Spec version mismatch (Spec Alignment)
// Compare: tech-spec frontmatter `based_on_spec_version` vs spec.md `spec_version`

// Missing file inventory (Completeness)
// Check: File Inventory section exists and has at least one row

// Reuse audit (Spec Alignment) — see the Reuse-audit gate in step 2 for severities
// Refuse approval (blocks feature-plan) if: section missing, OR table empty (0 data
//   rows), OR any row Decision not exactly {reuse, skip}, OR any `skip` row without a
//   non-dash Reason (this also covers a blanket-skip table with any Reason-less row).
// High finding (not a refusal): every row is `skip` but each has a substantive Reason —
//   ask the author to re-confirm nothing is reusable.
// Skip this check entirely if .myspec.json has reuseAudit.enabled === false

// Missing edge cases (Completeness)
// Check: Edge Cases section exists and has at least one item

// Vague steps (Step Granularity)
/\b(set up|configure|implement|add support for)\b/gi  // Flag if step has no specific files
```

## Output Format

**REQUIRED:** Follow [../\_shared/review-output.md](../_shared/review-output.md) for the findings table, fix-proposal shape, and tagging rules. Example row for this skill:

```markdown
| Critical | Spec Alignment | Version mismatch | tech-spec.md | 4 | `based_on_spec_version: 1` but spec.md has `spec_version: 3` |
```

The `[requires confirmation]` case that recurs here is a decompose proposal:

```markdown
## Fix 2: Split into sub-features (High) [requires confirmation]

**Issue**: Tech-spec covers both query logging AND analytics dashboard — independent capabilities that could ship separately.

**Proposed split** (via `/myspec:feature-decompose`):
1. `search/query-logging` — SearchQuery model, logging service, middleware hook
2. `search/analytics` — Dashboard page, aggregation queries, charts (depends on query-logging)

**Rationale**: Query logging is useful and shippable without the dashboard. Dashboard depends on logging data but not vice versa.

**ACTION REQUIRED**: Confirm or reject this split before proceeding.
```

## Severity Classification

| Severity | Definition | Must Fix Before |
|----------|------------|-----------------|
| **Critical** | Blocks implementation — spec version mismatch, missing core implementation path, contradictory steps | `/myspec:feature-plan` |
| **High** | Must fix — missing patterns, wrong conventions, scope issues, missing test strategy, split recommended | `/myspec:feature-plan` |
| **Medium** | Should fix — missing edge cases, vague steps, incomplete file inventory | implementation |
| **Low** | Nice to have — wording improvements, additional detail, documentation polish | feature-complete |

## Cross-File Validation Rules

### tech-spec.md → spec.md
- Every requirement ID in spec.md has a Requirement Coverage row naming at least one implementation step
- Every acceptance criterion must be traceable to a file in the inventory or a step
- `based_on_spec_version` must match spec.md `spec_version`

### tech-spec.md → dependencies.md
- Cross-feature dependencies mentioned in tech-spec must appear in dependencies.md
- If tech-spec imports from another feature's code, that feature must be in dependencies.md

### tech-spec.md → codebase patterns
- File paths follow naming and organization conventions defined in `.claude/rules/` or `${aiDir}/conventions/`
- Models include required audit fields per project database conventions (if defined)

## Verification Checklist

After running the skill:

- [ ] All 10 review dimensions checked against tech-spec.md
- [ ] Each implementation step is task-extractable (concrete enough for a plan task without interpretation)
- [ ] Reuse-audit gate applied: section present, >= 1 row, valid Decision/Reason (or `reuseAudit.enabled: false`)
- [ ] `based_on_spec_version` matches spec.md `spec_version`
- [ ] Verification-surface gate applied when `verification_mode` is set and not `none`: `### Test Hooks` has Target, Contract surface, and Scratch environment for `visual` / `mixed`, *Real inputs*, or data-mutating flows; no unstable references
- [ ] Requirement Coverage table built from spec.md, one row per requirement ID; every empty Steps cell reported as Critical; every `narrows` / `contradicts` Fidelity cell reported as High / Critical
- [ ] File inventory paths follow project conventions (per `.claude/rules/` or `${aiDir}/conventions/`)
- [ ] Models include required audit fields (if project defines them)
- [ ] Service/component patterns match project conventions
- [ ] Implementation steps are in dependency order
- [ ] Each step has reasonable granularity (single responsibility)
- [ ] Edge Cases section is non-empty
- [ ] Issues categorized by severity (Critical/High/Medium/Low)
- [ ] Each finding includes file name and line numbers
- [ ] Small fixes applied automatically without asking
- [ ] Big fixes proposed with `[requires confirmation]` tag and awaited
- [ ] `last_updated` set to today after changes
- [ ] Summary shows files changed and remaining issues

## Integration

**Called by** [OPTIONAL]: `/myspec:feature-tech-spec` (after tech-spec is created and user wants review)
**Next** [REQUIRED]: `/myspec:feature-plan` — create execution-ready implementation plan once tech-spec passes review
