# Spec Reviewer Dispatch Envelope (Orchestrator Mode)

Controller renders this envelope and passes it as the prompt body when dispatching a `reviewer-base` agent for spec review. The agent owns the output contract (`<verdict>PASS</verdict>` / `<verdict>FAIL-SPEC …</verdict>` / `<verdict>ESCALATE …</verdict>`) and ROBOT MODE rules — see `~/.claude/agents/reviewer-base.md`, `~/.cursor/agents/reviewer-base.md`, or `~/.codex/agents/reviewer-base.toml`. This envelope owns per-milestone inputs and the gate logic.

Dispatched after all Workers in a milestone report `OK`. Verdict gates the QualityReviewer.

## Envelope template

```
FAIL label = FAIL-SPEC

Inputs (inline, do not re-read the plan file):
{{SPEC_RELEVANT_BLOCK}}

{{TECH_SPEC_RELEVANT_BLOCK}}

{{PLAN_MILESTONE_BLOCK}}

Worker diff to review: git diff {{MILESTONE_BASE_SHA}}..HEAD

Gates (run in order, stop at first fail):
1. plan ↔ spec — does the plan correctly cover the spec's acceptance criteria for this milestone? Missing or wrongly-scoped tasks? FAIL → ESCALATE.
2. impl ↔ plan — does the diff implement every task in the plan? Exact file paths, interfaces, behaviors? FAIL → FAIL-SPEC.
3. TDD evidence — do the tests added by Workers verify spec-required behavior (not just exercise code)? Run the plan's test commands. FAIL → FAIL-SPEC.

Verify independently. Run the test commands. Do not trust Worker reports.

Routing examples (load-bearing — most reviewers conflate these axes):

  ESCALATE — plan layer mismatch:
    Spec §3.2 requires UUID format for tag IDs. The plan's Task 2 says
    "add length check on tag IDs" with no mention of UUID validation.
    Workers cannot derive UUID from "length check" — the plan must be
    updated by the user. Pause the run.

  FAIL-SPEC — impl layer mismatch:
    Plan Task 2 says "add uuid() validator before length check in
    applyTagSchema". Diff shows length check only; uuid() call is
    absent. Worker can fix verbatim by inserting the missing call.

  Heuristic: if the fix requires editing the plan task text, it is
  ESCALATE. If the fix is editing code to match what the plan already
  says, it is FAIL-SPEC. When in doubt, prefer ESCALATE — pausing for
  a human is cheaper than three retries patching a plan-layer gap at
  the impl layer.

Be specific in fix lines. "applyTagSchema in tags.ts:15 does not enforce
UUID format required by spec §3.2; fix: add `uuid()` validator before
length check" beats "missing validation".
```

## Controller substitution protocol

1. Render envelope verbatim. Do NOT wrap in "Job / Inputs / Verification / Report" headers.
2. Substitute `{{SPEC_RELEVANT_BLOCK}}`, `{{TECH_SPEC_RELEVANT_BLOCK}}`, `{{PLAN_MILESTONE_BLOCK}}` with the verbatim relevant sections (paste, do not summarize). `{{MILESTONE_BASE_SHA}}` is the SHA recorded at milestone start.
3. The reviewer should not need any other context. If it does, the plan task or the spec is under-specified — fix that, do not loosen the reviewer.

## Verdict routing

- `PASS` → dispatch QualityReviewer.
- `FAIL-SPEC` → re-dispatch failing Worker(s) with the bullet list appended verbatim under a `## Reviewer verdict (retry N)` header in the Worker envelope.
- `ESCALATE` → pause the run; surface verdict block to the user; require plan fix (`/myspec:feature-update` or re-run `/myspec:feature-plan`) before resuming.

## Dispatch invocation

- **Claude Code:** `Task` with `subagent_type: reviewer-base`, `description: "SpecReview — Milestone N"`, `model` resolved from `roles.spec_reviewer` (default `mid`), `prompt` = rendered envelope.
- **Cursor:** invoke the `reviewer-base` subagent (`~/.cursor/agents/reviewer-base.md`) with rendered envelope.
- **Codex:** invoke the `reviewer-base` subagent (`~/.codex/agents/reviewer-base.toml`) with rendered envelope.

Verdict block violations (prose around bullets, "Verdict:" prefix, summary paragraphs after the list) are bugs. Tighten the envelope or replace the reviewer model; do not loosen the controller parser.
