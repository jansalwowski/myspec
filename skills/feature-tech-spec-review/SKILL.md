---
name: feature-tech-spec-review
description: "Use when a tech-spec.md needs review for implementability, spec alignment, and pattern conformance before planning. Keywords: validate technical design, critique tech-spec. Do NOT use for spec.md (feature-spec-review) or code (built-in /code-review)."
tags: [feature, tech-spec, validation, critical-thinking, review]
---

# Feature Tech-Spec Review

**Autopilot:** when the user opted in, answer this skill's gates per [`_shared/autopilot.md`](../_shared/autopilot.md).

## Arguments

- `/myspec:feature-tech-spec-review {feature}`: the workflow below.
- `--from-author`: `feature-tech-spec` runs this review right after writing the tech-spec. Step 8 adds one re-review round and Step 9 skips its next-step recommendation; control returns to `feature-tech-spec`.

## Independent Reviewer

Steps 1–6 are in [reviewer.md](reviewer.md) and run in a fresh subagent, so the review never reads the tech-spec with the context of whoever wrote it. Dispatch it per [`_shared/spec-reviewer-prompt.md`](../_shared/spec-reviewer-prompt.md), with `[REVIEWER_PATH]` set to `${CLAUDE_PLUGIN_ROOT}/skills/feature-tech-spec-review/reviewer.md`. It tags each fix per [`_shared/review-output.md`](../_shared/review-output.md#tagging-and-application-rules). Show the Requirement Coverage table, findings table and fix proposals it returns as they came back, with the reviewer's wording, then continue at Step 7. When the Agent tool is not available or the dispatch fails, read that file, run Steps 1–6 yourself and say so in one line.

## Workflow

Steps 1–6 (load context, structure and gates, review dimensions, spec alignment, pattern conformance, findings and fix proposals) run in the reviewer, per [reviewer.md](reviewer.md). The gates there that refuse approval are High or Critical findings, so Step 9 sees them.

7. **Classify and Apply Fixes**
   - Tag each proposal `[auto-fix]` or `[requires confirmation]` per [review-output.md](../_shared/review-output.md#tagging-and-application-rules). Apply `[auto-fix]` immediately. For `[requires confirmation]` (for example a split into sub-features, a removed or reordered step, a changed interface), propose and WAIT.
   - Use diff format: `- old text` / `+ new text`

8. **Execute Changes**
   - Apply `[auto-fix]` proposals and confirmed `[requires confirmation]` proposals
   - Update `last_updated` date in frontmatter
   - If `based_on_spec_version` was stale but spec is unchanged: update it
   - With `--from-author`, when an applied `[requires confirmation]` fix changed the tech-spec: dispatch the reviewer once more, with `[PRIOR_FINDINGS]` filled, and take its findings through Steps 7–8. There is no third round; what it leaves open is listed in Step 9.

9. **Approve & Summary**
   - Show changes made (file paths, sections affected)
   - List remaining issues (if any were rejected)
   - If no Critical/High remain, ask: "Review passed — mark tech-spec.md `status: approved`?" On yes, set `status: approved` in tech-spec.md frontmatter — the transition `feature-plan` gates on (see the Status State Machine in `.claude/rules/feature-docs.md`). Otherwise it stays `draft`.
   - Recommend next step: re-review, `/myspec:feature-plan`, or address open issues first. With Critical/High remaining, do not recommend `/myspec:feature-plan`. With `--from-author`, skip it and return to `feature-tech-spec`, which recommends it.

## Verification Checklist

After running the skill:

- [ ] Steps 1–6 ran in a reviewer subagent given only the paths, or the fallback was announced
- [ ] The returned findings cover reviewer.md's checks and gates, with severity, file and line, and include the Requirement Coverage table
- [ ] `[auto-fix]` fixes (per `_shared/review-output.md`) applied without asking
- [ ] `[requires confirmation]` fixes proposed and awaited
- [ ] `last_updated` set to today after changes
- [ ] Summary shows files changed and remaining issues

## Integration

**Called by** [OPTIONAL]: `/myspec:feature-tech-spec` with `--from-author` (the user chose the review up front)
**Next** [REQUIRED]: `/myspec:feature-plan` — create execution-ready implementation plan once tech-spec passes review
