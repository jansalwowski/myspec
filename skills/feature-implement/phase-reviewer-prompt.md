# Phase Reviewer Prompt Template

Dispatch this reviewer after ALL tasks in a phase complete and worktrees are merged.

Before dispatching, write the review package to one file and substitute its path below. A pasted diff parks itself permanently in the controller's context, and a reviewer without one rebuilds it by hand — the single biggest reviewer cost:

```bash
PKG=$(mktemp "${TMPDIR:-/tmp}/phase-review.XXXXXX")
{ git log --oneline "$PHASE_BASE"..HEAD; echo; git diff --stat "$PHASE_BASE"..HEAD; echo; git diff -U10 "$PHASE_BASE"..HEAD; } > "$PKG"
```

`PHASE_BASE` is the sha recorded before the phase's first dispatch — never `HEAD~1`, which silently drops all but the last commit of a multi-commit phase.

Substitute the barrier verification log (`VERIFY_LOG`, SKILL.md Step 4a) and the spec requirement IDs the phase touches as well, plus `[SCRATCH_CHECKLIST path]` — `../_shared/scratch-isolation.md` resolved to an absolute path from this skill's directory (the reviewer runs in the project checkout, where the plugin's files do not live); paste the file's contents when that path is not readable from there.

```
Task tool (general-purpose):
  description: "Phase review for Phase N: [phase name]"
  model: "<mid tier — REQUIRED; e.g. Sonnet-tier, GPT-5-tier; controller picks concrete model. An omitted model inherits the session's model, often the most expensive tier>"
  prompt: |
    You are reviewing Phase N of the [feature name] implementation.

    ## Phase Summary

    This phase included the following tasks:
    [List each task with: task name, files created/modified, implementer's reported status]

    ## What Was Requested

    [FULL TEXT of all tasks in this phase from the plan — paste inline]

    ## Spec and Acceptance Criteria

    [Relevant acceptance criteria from spec.md for the work done in this phase]

    ## Spec Requirements This Phase Touches

    [Each requirement ID (R-number / AC ID) the phase's tasks implement or change, with its text verbatim]

    ## Diff Under Review

    **Base:** [PHASE_BASE sha]  **Head:** [HEAD sha]
    **Package file:** [PKG path]

    Read the package file once — it contains the phase's commit list, a stat
    summary, and the full diff with surrounding context. It is your view of
    the change; do not rebuild it with git commands. If the file is missing,
    fetch the diff yourself: `git log --oneline`, `git diff --stat`, and
    `git diff -U10` over [PHASE_BASE sha]..[HEAD sha]. Inspect code outside
    the diff only to evaluate a concrete risk you can name — one focused
    check per named risk; each listed requirement ID counts as one — and
    name both the risk and what you checked in your report.

    ## Barrier Verification Log

    **Log file:** [VERIFY_LOG path]

    The controller ran the full suite once at this phase's barrier; the
    log holds each check's command, exit code, and output. Read it — do not
    re-run the suite. Another suite run in this worktree races the
    controller's and produces timing flakes.

    Your review is read-only on this checkout, except for running the
    commands named under Test coverage. Never edit files or mutate the
    index, HEAD, or branch state.

    ## You Do Not Dispatch Subagents

    Do all of this review yourself. Never spawn a subagent to review part of
    the diff, and never spawn another reviewer for a second opinion. This
    process already provides every review seat the work gets; a reviewer you
    spawn duplicates one of them at full cost, and its verdict counts for
    nothing. If the diff feels too large for one pass, review it in passes
    yourself and say so in your report.

    ## Verify Independently — Don't Trust the Reports

    Implementer agents commonly over-report completeness, miss requirements, or misinterpret specs without realizing it. Skipping independent verification is how broken phases reach holistic review.

    Treat the implementers' reports as unverified claims about the code — including any check they say they ran. Evidence is the barrier log and the commands you run yourself; compare implementation to requirements line by line. Design rationales are claims too: "kept it simple deliberately", "left it per YAGNI", or any other justification is the implementer grading their own work. Judge the code on its merits — a stated rationale never downgrades a finding's severity.

    ## Your Job

    Review the entire phase holistically. Check:

    **Spec compliance (per task):**
    - Is everything requested actually implemented?
    - Are there requirements skipped or missed?
    - Did any task over-build (extra features not requested)?
    - Did any task misunderstand requirements?

    **Code quality:**
    - Is code clean and maintainable?
    - Do names accurately reflect what things do?
    - Are patterns from the existing codebase followed?
    - No magic numbers, no unnecessary complexity?

    **Spec requirements (whole feature):**
    For each requirement ID listed above, check that it holds as a behavior
    across the whole feature, not only in the task text that cites it. Look
    for another code path, an earlier phase, or a sibling mode (single vs.
    many, empty vs. full, create vs. update) that contradicts it. A
    requirement the task satisfies but the feature breaks is a finding.

    **Test coverage:**
    - Do tests exist for new functionality?
    - Do tests verify behavior (not just that code runs)?
    - Are edge cases covered?
    - Do all tests pass? Every failure in the barrier log is attributed
      below. Then run each task's `Verify at phase review:` command
      yourself, plus any further check needed to prove a risk you name —
      never the whole suite. Report the exact command and its output for
      each. If you run a `.claude/verification.json` check whose
      `diffCommand` is non-empty, run that instead of its `command`, with
      `MYSPEC_BASE_REF` set to `git merge-base HEAD <default branch>`.
      Export a fresh `MYSPEC_CHECK_RUN_ID` for each one. If a check is
      killed or times out and it declares a `cleanup`, run that with the
      same `MYSPEC_CHECK_RUN_ID` before running the check again. The kill stops only the local client, and work it started in
      a container or on another host keeps running.
    - For an invariant over real output ("output unchanged", "byte-identical",
      "never splits"), prefer a real-engine / real-data check over a mock: a
      test that mocks the engine pins what the mock returns, not what the
      engine does. Run one yourself on scratch infrastructure (the checklist
      at [SCRATCH_CHECKLIST path]), or flag the missing real-engine
      coverage as Important.

    **Test-weakening audit (mandatory):**
    Implementers may run their own tests, so the cheapest way past a red
    test — changing the test — was open to them. Walk every test, fixture,
    and lint/type config change in the diff for:
    - deleted assertions, or assertions loosened (exact → partial, truthy,
      `any`, snapshot rewritten to match)
    - added skips, `.only`, `todo`, `xfail`, or relaxed timeouts/thresholds
    - lint or type-check disables (`eslint-disable`, `@ts-ignore`,
      `@ts-expect-error`, `noqa`, `type: ignore`)
    - `as any` / `as unknown as` casts, or types widened to make code compile
    - fixtures whose values no longer match the production values they
      stand for, or no longer exercise what the test title claims
    Each unjustified hit is Important — Critical when it hides a real
    defect. A fixture set to a non-production value can mask exactly the
    bug the test exists to catch.

    **Attributing a failing check:**
    A repo can be red before this phase started. A whole-repo lint, type-check,
    or test command that exits non-zero is not by itself a finding — the
    finding is a failure this phase caused. Before reporting one, establish
    which it is: every failure it reports must name a file in the phase diff,
    or a symbol the phase diff introduced or changed. If it does not, the
    failure is pre-existing debt — say so, name it as out of scope, and do not
    open a fix round over it. Never resolve the ambiguity by weakening the
    command or narrowing what you run.

    **Integration:**
    - Do imports resolve correctly across all new files?
    - No type errors between task outputs?
    - Does the phase output form a coherent, shippable unit?

    **File scope (parallel tasks only):**
    - Did each parallel task only touch its declared files?
    - Were there unexpected cross-task file modifications?

    **Docs consistency:**
    - If any docs were referenced in the plan as needing updates, are they updated?
    - Do any interfaces or types in the plan match what was actually implemented?

    ## Severity Calibration

    Categorize every issue by actual severity. **Critical**: broken behavior,
    data loss, security. **Important**: this phase cannot be trusted until it
    is fixed — incorrect or fragile behavior, a missed requirement, or
    maintainability damage you would block a merge over (verbatim duplication
    of a logic block, swallowed errors, tests that assert nothing).
    **Minor**: "coverage could be broader" and polish suggestions. Only
    Critical and Important enter the fix loop; Minor findings are parked for
    the holistic review — so an inflated Minor wastes a fix round and a
    deflated Important ships a defect.

    If the plan or task text explicitly mandates something this review treats
    as a defect (a test that asserts nothing, verbatim duplication of a logic
    block), that IS a finding — report it as Important, labeled
    plan-mandated. The plan's authorship does not grade its own work; the
    controller rules on it with the spec as the binding authority.

    ## Report Format

    Your final message is the report itself: begin directly with the first
    per-task verdict. Every line is a verdict, a finding with file:line, or a
    check you ran — no preamble, no process narration, no closing summary.

    **Per-task verdict:**
    - Task N: ✅ APPROVED | ❌ ISSUES: [specific problems with file:line references]

    **Spec requirements:** one line per listed ID — holds | violated (file:line)

    **Test-weakening audit:** each hit with file:line, or "none found"

    **Issues by severity** (each: file:line, what is wrong, why it matters, how to fix if not obvious):
    - Critical: …
    - Important: …
    - Minor: …

    **Overall phase verdict:**
    - APPROVED — All tasks pass, phase is shippable
    - ISSUES_FOUND — [all Critical/Important issues by task, with file:line references and what needs to change]

    Be specific. Vague feedback wastes time. "Missing validation" is bad. "applyTagSchema in tags.ts:15 does not validate that tagId is a valid UUID format" is good.
```
