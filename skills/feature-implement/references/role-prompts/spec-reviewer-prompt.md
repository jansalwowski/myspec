# Spec Reviewer Dispatch Envelope (Orchestrator Mode)

Controller renders this envelope and dispatches `reviewer-base`. The agent definition owns the verdict-block contract and rules. This file owns the per-task inputs and gate logic.

Dispatched after each Worker reports `OK`. Verdict gates QualityReviewer. Substitution + dispatch invocation discipline lives in `orchestrator-dispatcher.md` → "Dispatch envelope discipline (shared)".

Per-task scope: Worker's edits are uncommitted at review time (controller commits only after both reviewers PASS). `git diff HEAD` shows the working-tree changes for the current task. `git diff A..HEAD` would compare two commits and silently miss the unstaged worker output — do not use it.

## Envelope template

```
FAIL label = FAIL-SPEC

Inputs (inline, do not re-read the plan file):
{{SPEC_RELEVANT_BLOCK}}

{{TECH_SPEC_RELEVANT_BLOCK}}

{{PLAN_TASK_BLOCK}}

Worker diff to review: git diff HEAD

Gates (run in order, stop at first fail):
1. plan ↔ spec — does the plan task cover the spec's acceptance criteria it claims to address? Missing or wrongly-scoped requirements? FAIL → ESCALATE.
2. impl ↔ plan — does the diff implement the task in the plan? Exact file paths, interfaces, behaviors? FAIL → FAIL-SPEC.
3. TDD evidence (STATIC ONLY — do NOT run tests; QualityReviewer runs them) — does the diff add or modify a test that exercises the spec-required behavior named in this task? For each in-scope acceptance criterion, confirm a test exists in the diff. If a test is missing or exercises only happy-path while the spec calls out edge/error behavior, FAIL → FAIL-SPEC.

Verify independently against the spec quotes inline above. Do not trust Worker reports.

Routing — load-bearing (most reviewers conflate these axes):

  ESCALATE — plan layer mismatch:
    Spec §3.2 requires UUID format for tag IDs. Plan Task 2 says "add length
    check on tag IDs" with no mention of UUID validation. Workers cannot
    derive UUID from "length check" — plan must be updated by the user.

  FAIL-SPEC — impl layer mismatch:
    Plan Task 2 says "add uuid() validator before length check in
    applyTagSchema". Diff shows length check only; uuid() call absent.
    Worker can fix verbatim.

  Heuristic: if the fix requires editing the plan task text, it is ESCALATE.
  If the fix is editing code to match what the plan already says, it is
  FAIL-SPEC. When in doubt, prefer ESCALATE.

Be specific in fix lines. "applyTagSchema in tags.ts:15 does not enforce
UUID format required by spec §3.2; fix: add `uuid()` validator before
length check" beats "missing validation".
```

## Slots

- `{{SPEC_RELEVANT_BLOCK}}`, `{{TECH_SPEC_RELEVANT_BLOCK}}`, `{{PLAN_TASK_BLOCK}}` — verbatim relevant sections (paste, do not summarize).

## Verdict routing

- `PASS` → dispatch QualityReviewer.
- `FAIL-SPEC` → re-dispatch failing Worker(s) with bullet list appended verbatim under `## Reviewer verdict (retry N)` in the Worker envelope.
- `ESCALATE` → pause; surface verdict to user; require plan fix (`/myspec:feature-update` or re-run `/myspec:feature-plan`) before resuming.
