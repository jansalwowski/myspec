---
name: feature-status-audit
description: "Use when the whole feature manifest needs auditing against on-disk docs, or delivery metrics across features are wanted. Keywords: manifest drift, index.yaml audit, orphan features, docs ahead of status, stale status, plan checkbox drift, feature inventory, lead time, rework rate. Do NOT use for one feature's deep audit (feature-verify)."
allowed-tools: [Bash, Read]
---

# Feature Status Audit

Batch cross-check of `${aiDir}/features/index.yaml` (and per-feature sub-indexes) against actual documentation files on disk. Complements `/myspec:feature-verify` — this skill scans **all** features in seconds; `/myspec:feature-verify` does a deep 8-category audit on **one** feature.

**Core principle:** Read-only. Never modifies files. Flags mismatches; routes to fix skills per feature.

## Workflow

### 1. Run the script

From the project root:

```bash
node "${CLAUDE_PLUGIN_ROOT}/lib/feature-status-audit/audit.mjs"
```

The script auto-detects `aiDir` from `.myspec.json` (falls back to `ai`). No npm dependencies.

Useful flags:

| Flag | Purpose |
|------|---------|
| `--ai-dir=<path>` | Override ai dir (e.g. `--ai-dir=docs`) |
| `--only=<name>` | Restrict to one feature and its sub-features |
| `--severity=<critical\|high\|medium\|low>` | Hide issues below this threshold (default: low) |
| `--json` | Machine-readable output (for piping into other tools) |

Exit codes: `0` clean, `1` high-severity issues, `2` critical issues, `3` script error.

### 2. Interpret the report

The script outputs:

- **Summary** — totals (healthy, with issues, counts by severity, orphan dir count)
- **Issues table** — one row per issue: `Feature | Status | Severity | Message`
- **Orphan directories** — dirs under `features/` not registered in any manifest
- **Healthy roll-up** — compact list of features with zero issues

### 3. Severity → fix skill routing

| Issue pattern | Recommended skill |
|---------------|-------------------|
| `directory missing` (status ≥ in-progress) | `/myspec:feature-spec-sync` or delete the manifest entry |
| `required doc missing for status=complete` | `/myspec:feature-spec` or `/myspec:feature-tech-spec` |
| `required doc missing for status=in-progress` | `/myspec:feature-spec` |
| `tech-spec/implementation-plan present but status=planned` (docs ahead) | bump manifest status |
| `draft with no documentation files` | `/myspec:feature-spec` or remove manifest entry |
| `subfeatures: true but no index.yaml` | create the sub-feature manifest |
| `implementation-plan.md still present though status=complete` | archive into `plans/` via `/myspec:feature-complete` |
| `implementation-plan.md is N/N [x] but status=draft\|in-progress` | confirm the merge (see the `git log:` hint line), then `/myspec:feature-complete` |
| `status=complete but implementation-plan.md is k/N [x]` | finish or defer the open tasks, then `/myspec:feature-complete`; or revert status |
| `archived plans/... is 0/N [x]` | `/myspec:feature-verify <name>` — the plan was archived without being ticked, or the work never happened |
| `spec.md` / `tech-spec.md frontmatter status: draft` under `complete` | bump the doc's frontmatter `status` |
| `all N sub-features complete but spec.md acceptance criteria are k/M [x]` | `/myspec:feature-verify <parent>` — tick delivered ACs or split the rest into a new sub-feature |
| Orphan directory | register in manifest or delete |

### 4. Hand off

Present the report to the user. Do NOT attempt fixes automatically. Ask which issue they want to tackle, then invoke the routed skill (usually `/myspec:feature-verify <name>` for a deep dive on the worst offender, then `/myspec:feature-spec-sync` or the relevant fix skill).

### 5. Optional: delivery metrics

Run only when the user asks how delivery is going (lead time, rework, deferrals) or for a periodic review. It is a separate read-only script, and its numbers are outcomes, not drift: never route them to a fix skill.

```bash
node "${CLAUDE_PLUGIN_ROOT}/lib/delivery-metrics/metrics.mjs"   # add --json, --feature=<id>, --since=YYYY-MM-DD
```

It computes, per feature and in aggregate, from git history plus the feature docs: spec→complete lead time, stage dwell per manifest status, plan deferral rate, conformance first-time pass, 30-day rework rate over the tech-spec File Inventory paths, and spec churn after completion. Each metric's definition is printed with the report (`definitions` in `--json`). A metric it cannot compute is `null` with a reason, and it exits 3 in a shallow clone rather than report truncated history.

When presenting:
- Quote the definitions line for any metric you discuss, and report `null` reasons as they are; never estimate a missing value.
- Rework counts a commit as a fix when its subject matches the printed fix pattern (Conventional Commits `fix:` plus common free-form prefixes). If the project's commits follow another convention, say so and re-run with `--fix-pattern=<regex>`.
- First-time pass reads committed verdict history only, so it is a lower bound on failures. `/myspec:feature-implement-review` overwrites `conformance-report.md` without committing, and squash merges drop earlier versions. A failure that was overwritten leaves no trace, so a high pass rate does not show that reviews pass first time.
- Lead time excludes features first seen already `complete` (retroactive docs, decomposed sub-features, whole flows landed in one squash commit); the aggregate line gives how many. A manifest rename it cannot link on its own needs `renamedFrom: <old name>` on the entry.
- `Open` counts plan tasks on complete features that are neither ticked nor marked deferred. They are outside the deferral rate, and they are usually unmarked scope cuts.
- With fewer than about five features in an aggregate (`n`), call it anecdotal.

## Status → expected docs matrix

The script encodes this policy. Reference when explaining flags:

| Status | Required | Expected | "Docs ahead" signal |
|--------|----------|----------|---------------------|
| `planned` | — | — | `tech-spec.md` or `implementation-plan.md` present |
| `draft` | `spec.md` | `dependencies.md` | `implementation-plan.md` present |
| `in-progress` | `spec.md` | `tech-spec.md`, `dependencies.md` | — |
| `complete` | `spec.md`, `tech-spec.md` | — | `implementation-plan.md` present (should be archived) |
| `deprecated` | — | — | — |

## Status drift checks

Beyond file presence, the script compares the manifest status against what the docs say:

| Check | Fires when |
|-------|-----------|
| Plan ratio | Non-complete status with `implementation-plan.md` 100% `[x]`; `complete` with an unarchived plan holding `[ ]`/`[~]`; `complete` with any `plans/*.md` at 0/N |
| Doc status | `spec.md` or `tech-spec.md` frontmatter `status: draft` while the manifest says `complete` |
| Parent ACs | Every sub-feature `complete` while the parent `spec.md` *Acceptance Criteria* section has unticked boxes; skipped when the spec ticks none (it does not use checkbox ACs) |

Counting takes list-item checkboxes (`[ ]`, `[~]`, `[x]`) only; table cells and fenced code are ignored. For a fully ticked plan under a non-complete status, the script adds up to three `git log --grep=<feature>` matches as a hint; nothing is printed outside a git repo. JSON output carries `planProgress`, `archivedPlans`, `specStatus`, `techSpecStatus`, and `gitHint` per feature. Symbols cited in review reports are not checked — that is `/myspec:feature-implement-review`'s job.

## Edge cases

- **Hyphenated vs non-hyphenated top key**: script accepts both `features:`, `subfeatures:`, `sub-features:`.
- **Sub-feature names with or without parent prefix**: `search/core` (prefixed) and `map-surface-adapter` (bare under parent `coverage-editor`) are both resolved correctly.
- **No sub-index file despite `subfeatures: true`**: flagged as High.
- **Multi-line YAML values or anchors**: the parser is purpose-built for this manifest shape and ignores fields it doesn't recognize. If it fails on a project, fall back to `--json` mode and inspect raw output, then report the shape to the myspec maintainer.

## Verification Checklist

- [ ] Ran `node "${CLAUDE_PLUGIN_ROOT}/lib/feature-status-audit/audit.mjs"` from project root
- [ ] Reviewed summary counts (healthy vs with issues)
- [ ] Read the issues table top-to-bottom, grouping by feature
- [ ] Cross-checked at least one flagged "directory missing" by running `ls ${aiDir}/features/<name>/`
- [ ] For each plan-ratio flag with a `git log:` hint, checked whether the work actually merged before routing
- [ ] Noted orphan directories separately (they often represent renamed features)
- [ ] Routed each flagged feature to the right fix skill rather than fixing ad-hoc
- [ ] If delivery metrics were run: every `null` reported with its reason, not estimated, and the fix-pattern assumption stated with the rework rate
- [ ] Did not modify any files during the audit

## Integration

**Call before:** project-wide cleanup sweeps, release prep, after large refactors, or as a periodic (weekly/monthly) health check.
**Complements:** OPTIONAL `/myspec:feature-verify` — single-feature deep audit. Run this audit first to find the feature most needing attention, then drill in with `feature-verify`.
**Routes to (all OPTIONAL):** `/myspec:feature-verify`, `/myspec:feature-spec-sync`, `/myspec:feature-spec`, `/myspec:feature-tech-spec`, `/myspec:feature-complete`.
