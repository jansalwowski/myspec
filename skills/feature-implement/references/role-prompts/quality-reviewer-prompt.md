# Quality Reviewer Dispatch Envelope (Orchestrator Mode)

Controller renders this envelope and passes it as the prompt body when dispatching a `reviewer-base` agent for quality review. The agent owns the output contract (`<verdict>PASS</verdict>` / `<verdict>FAIL-QUALITY …</verdict>`) and ROBOT MODE rules — see `~/.claude/agents/reviewer-base.md`, `~/.cursor/agents/reviewer-base.md`, or `~/.codex/agents/reviewer-base.toml`. This envelope owns the per-milestone checks and the scope rules.

Dispatched only after SpecReviewer returns `PASS`. Reviews code quality, not spec compliance.

## Envelope template

```
FAIL label = FAIL-QUALITY

Worker diff to review: git diff {{MILESTONE_BASE_SHA}}..HEAD

Out of scope:
- spec.md, tech-spec.md, acceptance criteria (SpecReviewer already cleared those — do not read them).
- Pre-existing content the diff did not touch, even when adjacent. If a problem lives on a line `git diff {{MILESTONE_BASE_SHA}}..HEAD` did not modify, IGNORE IT — it is not this milestone's regression. Stale links, dead code, magic numbers, naming nits in untouched lines are explicitly out of scope. Flagging pre-existing tech debt as FAIL-QUALITY is a contract violation.

In scope:
- Lines added or modified by the diff.
- Neighboring files for pattern reference (at most one or two per touched directory).

Checks:
1. Naming clarity — identifiers say what the code does.
2. Pattern conformance — new code matches existing codebase conventions in the touched directories.
3. Maintainability — dead code, magic numbers, unnecessary complexity, duplication.
4. Test quality — tests verify behavior, not just exercise code.
5. File scope (parallel tasks only) — each task touched only its declared files.

Browse minimally: read the diff, read at most one or two neighbor files per touched directory. Do not list directories, do not grep speculatively, do not open unrelated files. Typecheck/lint runs at the Checkpoint step in `orchestrator-dispatcher.md`, not here.

Be specific. "`doStuff` in tags.ts:42 should be `applyTagSchema` to match
neighbors in tags-validator.ts:8,17,29" beats "naming unclear".
```

## Controller substitution protocol

1. Render envelope verbatim. Do NOT wrap in "Job / Inputs / Checks / Report" headers.
2. Substitute `{{MILESTONE_BASE_SHA}}` with the SHA recorded at milestone start. No other slots.

## Verdict routing

- `PASS` → proceed to Checkpoint.
- `FAIL-QUALITY` → re-dispatch the same Worker(s) with the bullet list appended verbatim under a `## Reviewer verdict (retry N)` header in the Worker envelope.

## Dispatch invocation

- **Claude Code:** `Task` with `subagent_type: reviewer-base`, `description: "QualityReview — Milestone N"`, `model` resolved from `roles.quality_reviewer` (default `mid`), `prompt` = rendered envelope.
- **Cursor:** invoke the `reviewer-base` subagent (`~/.cursor/agents/reviewer-base.md`) with rendered envelope.
- **Codex:** invoke the `reviewer-base` subagent (`~/.codex/agents/reviewer-base.toml`) with rendered envelope.

Verdict block violations are bugs. Tighten the envelope or replace the reviewer model; do not loosen the controller parser.
