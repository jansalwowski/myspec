---
name: feature-spec-review
description: "Use when asked to review, check, critique or list problems in a feature's spec.md or requirements, usually before tech design — completeness, consistency, testability, scope, dependency hygiene. Keywords: review spec, spec problems, critique requirements, validate spec. Do NOT use for tech-spec.md (feature-tech-spec-review)."
tags: [feature, specification, validation, critical-thinking]
---

# Feature Spec Review

**Autopilot:** when the user opted in, answer this skill's gates per [`_shared/autopilot.md`](../_shared/autopilot.md).

## Arguments

- `/myspec:feature-spec-review {feature}`: the workflow below.
- `--from-author`: `feature-spec` runs this review right after writing the spec. Step 8 adds one re-review round and Step 9 skips its next-step question; control returns to `feature-spec`.

## Independent Reviewer

Steps 1–6 are in [reviewer.md](reviewer.md) and run in a fresh subagent, so the review never reads the spec with the context of whoever wrote it. Dispatch it per [`_shared/spec-reviewer-prompt.md`](../_shared/spec-reviewer-prompt.md), with `[REVIEWER_PATH]` set to `${CLAUDE_PLUGIN_ROOT}/skills/feature-spec-review/reviewer.md`. Show the findings table and fix proposals it returns as they came back, then continue at Step 7. When the Agent tool is not available or the dispatch fails, read that file, run Steps 1–6 yourself and say so in one line.

## Workflow

Steps 1–6 (load context, structure, review dimensions, dependency cross-check, findings, fix proposals) run in the reviewer, per [reviewer.md](reviewer.md).

7. **Wait for Confirmation**
   - Call `AskUserQuestion` so options are selectable — never render a plain bulleted list:
     ```
     question: "Which fixes should I apply?"
     header:   "Apply fixes"
     options:
       - "All"            → apply every proposed fix
       - "Critical+High"  → apply Critical and High severities only
       - "Individually"   → pick fixes one at a time
       - "None"           → leave spec unchanged
     ```
   - Order options so the recommended choice is first with `(Recommended)` appended.
   - `[auto-fix]` proposals, as defined in [review-output.md](../_shared/review-output.md#tagging-and-application-rules): apply immediately without asking. The question covers only `[requires confirmation]` proposals.
   - **Anything touching requirements, scope, or acceptance criteria** is `[requires confirmation]`: do NOT proceed without explicit approval. Spec content is the user's product intent.

8. **Execute Changes**
   - Apply auto-fixes and approved fixes to spec.md and/or dependencies.md
   - Increment `spec_version` in spec.md frontmatter
   - Update `last_updated` date in frontmatter (that is the field's name — do not add an `updated` field)
   - With `--from-author`, when an applied `[requires confirmation]` fix changed requirements, scope or acceptance criteria: dispatch the reviewer once more, with `[PRIOR_FINDINGS]` filled, and take its findings through Steps 7–8, without incrementing `spec_version` a second time: one review run is one version. There is no third round; what it leaves open is listed in Step 9.

9. **Approve & Next Step**
   - Show changes made (file paths, sections affected)
   - List remaining issues (if any)
   - If remaining Critical/High issues → recommend addressing those first; spec stays `status: draft`
   - If no Critical/High remain, ask: "Review passed — mark spec.md `status: approved`?" On yes, set `status: approved` in spec.md frontmatter. This is the transition `feature-tech-spec` and `feature-plan` gate on — without it the pipeline stalls (see the Status State Machine in `.claude/rules/feature-docs.md`).
   - Then call `AskUserQuestion`:
     ```
     question: "Spec is approved. What's next?"
     header:   "Next step"
     options:
       - "/myspec:cross-spec-validation"  → check against related specs for contradictions, broken contracts, or superseded assumptions
       - "/myspec:feature-tech-spec"      → skip cross-check, go straight to technical design
     ```
   - Mark `/myspec:cross-spec-validation` as `(Recommended)` — it is the default before tech-spec.
   - Wait for the user's choice before proceeding.
   - With `--from-author`, skip the next-step question and return to `feature-spec`, which offers it after its commit decision.

## Verification Checklist

After running the skill:

- [ ] Steps 1–6 ran in a reviewer subagent given only the paths, or the fallback was announced
- [ ] The returned findings cover reviewer.md's checks, with severity, file and line, and a diff-format fix for each
- [ ] `[auto-fix]` fixes applied without asking
- [ ] User confirmation was requested before changes
- [ ] If changes were made: spec_version was incremented
- [ ] If changes were made: `last_updated` was set to today
- [ ] Summary shows files changed and remaining issues

## Integration

**Called by** [OPTIONAL]: `/myspec:feature-spec` with `--from-author` (the user chose the review up front)
**Suggests** [OPTIONAL]: `/myspec:cross-spec-validation` — validate against related specs
**Next** [REQUIRED]: `/myspec:feature-tech-spec` — create technical design once spec is approved
