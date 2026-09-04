---
name: feature-status-audit
description: "Use when the whole feature manifest needs auditing against on-disk docs. Keywords: manifest drift, index.yaml audit, orphan features, docs ahead of status, feature inventory. Do NOT use for one feature's deep audit (feature-verify)."
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
| Orphan directory | register in manifest or delete |

### 4. Hand off

Present the report to the user. Do NOT attempt fixes automatically. Ask which issue they want to tackle, then invoke the routed skill (usually `/myspec:feature-verify <name>` for a deep dive on the worst offender, then `/myspec:feature-spec-sync` or the relevant fix skill).

## Status → expected docs matrix

The script encodes this policy. Reference when explaining flags:

| Status | Required | Expected | "Docs ahead" signal |
|--------|----------|----------|---------------------|
| `planned` | — | — | `tech-spec.md` or `implementation-plan.md` present |
| `draft` | `spec.md` | `dependencies.md` | `implementation-plan.md` present |
| `in-progress` | `spec.md` | `tech-spec.md`, `dependencies.md` | — |
| `complete` | `spec.md`, `tech-spec.md` | — | `implementation-plan.md` present (should be archived) |
| `deprecated` | — | — | — |

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
- [ ] Noted orphan directories separately (they often represent renamed features)
- [ ] Routed each flagged feature to the right fix skill rather than fixing ad-hoc
- [ ] Did not modify any files during the audit

## Integration

**Call before:** project-wide cleanup sweeps, release prep, after large refactors, or as a periodic (weekly/monthly) health check.
**Complements:** OPTIONAL `/myspec:feature-verify` — single-feature deep audit. Run this audit first to find the feature most needing attention, then drill in with `feature-verify`.
**Routes to (all OPTIONAL):** `/myspec:feature-verify`, `/myspec:feature-spec-sync`, `/myspec:feature-spec`, `/myspec:feature-tech-spec`, `/myspec:feature-complete`.
