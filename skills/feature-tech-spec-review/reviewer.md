# Feature Tech-Spec Review: Reviewer Steps

Steps 1–6 of `feature-tech-spec-review`. The reviewer subagent runs them. The main session runs them only when it cannot dispatch the reviewer. Steps 7–9 are in `SKILL.md`.

## Steps

1. **Load Context**
   - Read `${aiDir}/features/{feature}/tech-spec.md`
   - Read `${aiDir}/features/{feature}/spec.md`
   - Read `${aiDir}/features/{feature}/dependencies.md`
   - Read `${aiDir}/features/index.yaml` to verify feature status
   - Read `.claude/rules/` convention files if they exist (backend, frontend, database)
   - If sub-feature: also read parent tech-spec.md

2. **Analyze Structure**
   - Verify required sections exist and are not empty: Architecture, Reuse audit, Implementation Steps (at least one numbered step), Edge Cases (at least one item), File Inventory (at least one row)
   - Check optional sections present if relevant: Key Interfaces/Types, Database Changes, API Schema, API Endpoints, Decisions
   - **Reuse-audit gate** (skip only when the tech-spec carries `<!-- myspec:reuse-audit skip: <reason> -->` with a reason; a marker without one is a High finding). Each condition below is a **High** finding, so approval is refused and `/myspec:feature-plan` is not recommended. It applies when the `### Reuse audit` section is:
     - missing, OR
     - an empty table (header + separator only, zero data rows), OR
     - a blanket-skip audit (every row `skip`) with one or more rows lacking a `Reason`, OR
     - has any `skip` row with an empty / dash-only `Reason`, OR
     - has any row whose `Decision` is not exactly `reuse` or `skip`.
   - A blanket-skip audit where every row has a substantive `Reason` is allowed but warrants a High finding asking the author to re-confirm nothing is reusable.
   - **No verification mode on a data-deriving design**: when frontmatter has no `verification_mode` and the design derives output from input data (a parser, importer, converter, export, aggregation, or classification rule), report a Medium finding: `verification_mode: data` with Test Hooks *Real inputs* gets each milestone a probe on the inputs the rule must handle. Medium does not block approval or `/myspec:feature-plan`.
   - **Verification-surface gate** (skip when frontmatter has no `verification_mode`, or it is `none`). `verification_mode` must be one of `visual`, `api`, `data`, `mixed`, `none`. Otherwise the `### Test Hooks` section must exist with *Target* and *Contract surface* lines, plus *Scratch environment* when the mode is `visual` or `mixed` (feature-plan adds a `[demo]` probe there), when *Real inputs* is named (a `[real-input]` probe follows), or when the spec's flows mutate data. Probes do not exist yet at this stage, so decide from the mode and the Test Hooks lines, not from probes. Each missing line is High and blocks `/myspec:feature-plan`: `feature-plan` writes checkpoint probes only against these handles. A *Contract surface* entry that reaches past the public surface — a style class, internal element structure, private state — is High, naming the unstable reference.
   - Validate frontmatter has `title`, `status`, `based_on_spec_version`, `created`, `last_updated`

3. **Apply Review Dimensions**: check tech-spec.md against each of the 10 [Review Dimensions](#review-dimensions) and run the [Detection Patterns](#detection-patterns).

4. **Cross-Validate Spec Alignment**
   - Build the [Requirement Coverage](#requirement-coverage) table.
   - Every acceptance criterion in spec.md is traceable to a file in the inventory or a step.
   - No implementation step introduces functionality not in spec.md (scope creep).
   - `based_on_spec_version` matches spec.md `spec_version`. A mismatch is Critical.
   - Every cross-feature dependency the tech-spec mentions or imports from is listed in dependencies.md.

5. **Check Pattern Conformance** against `${aiDir}/conventions/` and `.claude/rules/`, where the project defines them:
   - File paths follow the expected project organization
   - Naming conventions are followed
   - Database models include the required audit fields
   - Service and component patterns match project conventions

6. **Present Findings and Fixes**: one table per the [Output Format](#output-format), grouped Critical → High → Medium → Low, with line numbers. Rate each finding by the [Severity Classification](#severity-classification). Then one fix proposal per finding in diff format (`- old text` / `+ new text`), tagged per [review-output.md](../_shared/review-output.md#tagging-and-application-rules).

## Review Dimensions

| Dimension | Detection Patterns | What to Check |
|-----------|-------------------|---------------|
| **Spec Alignment** | Requirement Coverage table has an empty Steps cell or a `narrows`/`contradicts` Fidelity cell; step with no spec backing | Every requirement ID maps to a step, no orphan steps, version match |
| **Feasibility** | Unknown packages, non-existent APIs, impossible constraints | Steps achievable with the project's tech stack (from `.myspec.json` or CLAUDE.md) |
| **Completeness** | `TBD`, `TODO`, `???`, empty sections, missing file inventory | All required sections present, all steps have detail |
| **Pattern Conformance** | Service/GraphQL/validator/component patterns | Step 5 checks |
| **Step Granularity** | Steps joining unrelated work with "and", single-line steps | Each step = single responsibility, ~1–4 hours |
| **Dependency Ordering** | Step N references types/files from Step N+M | Steps ordered so dependencies created before consumers |
| **Testability** | Steps without test files in inventory, no test strategy | Each step has verifiable output, test file in inventory |
| **Task-extractability** | Steps phrased as outcomes/intents ("handle errors", "add validation") with no named files, contracts, or concrete behavior | See [Task-Extractability](#task-extractability) |
| **YAGNI** | `future`, `extensible`, `scalable`, `flexible`, generic abstractions | No unused abstractions, no premature optimization |
| **Scope / Size** | Multiple independent capabilities, unrelated domains mixed | See [Scope Assessment](#scope-assessment) |

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

## Detection Patterns

```typescript
// Incomplete content (Completeness)
/\b(TBD|TODO|FIXME|\?\?\?|placeholder)\b/gi

// YAGNI indicators
/\b(future[- ]proof|extensible|scalable|flexible|generic|just in case)\b/gi

// Low finding: `[ ]`/`[x]` checkboxes in tech-spec.md (progress belongs in implementation-plan.md)

// Vague steps (Step Granularity)
/\b(set up|configure|implement|add support for)\b/gi  // Flag if step has no specific files
```

## Severity Classification

| Severity | Definition | Must Fix Before |
|----------|------------|-----------------|
| **Critical** | Blocks implementation — spec version mismatch, missing core implementation path, contradictory steps | `/myspec:feature-plan` |
| **High** | Must fix — missing patterns, wrong conventions, scope issues, missing test strategy, split recommended | `/myspec:feature-plan` |
| **Medium** | Should fix — missing edge cases, vague steps, incomplete file inventory | implementation |
| **Low** | Nice to have — wording improvements, additional detail, documentation polish | feature-complete |

## Output Format

Return the [Requirement Coverage](#requirement-coverage) table first, every row, so the user sees which requirement each step realizes and the Spec Alignment findings can be checked against it.

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
