# Quality Reviewer Dispatch Envelope (Orchestrator Mode)

Controller renders this envelope and dispatches `reviewer-base`. Agent definition owns the verdict-block contract and rules. This file owns per-task checks and scope rules.

Dispatched only after SpecReviewer returns `PASS`. Reviews code quality, not spec compliance. Substitution + dispatch invocation discipline lives in `orchestrator-dispatcher.md` → "Dispatch envelope discipline (shared)".

Per-task scope: Worker's edits are uncommitted at review time (controller commits only after both reviewers PASS). `git diff HEAD` shows the working-tree changes for the current task — including new files, because the controller stages worker-created paths as intent-to-add (`git add --intent-to-add`) before dispatching you. `git diff A..HEAD` would compare two commits and silently miss the unstaged worker output — do not use it.

## Envelope template

```
FAIL label = FAIL-QUALITY

Worker diff to review: git diff HEAD

Out of scope:
- spec.md, tech-spec.md, acceptance criteria (SpecReviewer cleared those).
- Pre-existing content the diff did not touch, even when adjacent. If a problem lives on a line `git diff HEAD` did not modify, IGNORE IT. Flagging pre-existing tech debt as FAIL-QUALITY is a contract violation.

In scope:
- Lines added or modified by the diff.
- Neighboring files for pattern reference (at most one or two per touched directory).

Checks:
1. Verification — run test, lint, and type-check commands declared in `.claude/verification.json` and any `Run` step in the task block. Non-zero exit → FAIL-QUALITY bullet per concrete error line (file:line citation when the tool gives one). Worker did not run these; SpecReviewer also did not. This dispatch is the sole verification pass.
2. Naming clarity — identifiers say what the code does.
3. Pattern conformance — new code matches conventions in the touched directories.
4. Maintainability — dead code, magic numbers, unnecessary complexity, duplication.
5. Test quality — tests verify behavior, not just exercise code.
6. File scope (parallel tasks only) — each task touched only its declared files.

Browse minimally. Run only verification commands declared in `.claude/verification.json` or the task block — do not invent extra commands.

Be specific. "`doStuff` in tags.ts:42 should be `applyTagSchema` to match neighbors in tags-validator.ts:8,17,29" beats "naming unclear".
```

## Slots

(none — `git diff HEAD` carries the worker's uncommitted changes; no SHA substitution needed)

## Verdict routing

- `PASS` → controller commits, then proceed to next task (or Checkpoint).
- `FAIL-QUALITY` → re-dispatch the same Worker(s) with bullet list appended verbatim under `## Reviewer verdict (retry N)` in the Worker envelope.
