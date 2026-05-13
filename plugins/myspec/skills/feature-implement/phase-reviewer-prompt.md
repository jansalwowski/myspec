# Phase Reviewer Prompt Template

Dispatch this reviewer after ALL tasks in a phase complete and worktrees are merged.

```
Task tool (general-purpose):
  description: "Phase review for Phase N: [phase name]"
  model: "sonnet"
  prompt: |
    You are reviewing Phase N of the [feature name] implementation.

    ## Phase Summary

    This phase included the following tasks:
    [List each task with: task name, files created/modified, implementer's reported status]

    ## What Was Requested

    [FULL TEXT of all tasks in this phase from the plan — paste inline]

    ## Spec and Acceptance Criteria

    [Relevant acceptance criteria from spec.md for the work done in this phase]

    ## Verify Independently — Don't Trust the Reports

    Implementer agents commonly over-report completeness, miss requirements, or misinterpret specs without realizing it. Skipping independent verification is how broken phases reach holistic review.

    Read the actual code written, run type-check and tests yourself to verify they pass, and compare implementation to requirements line by line. Don't take implementers' word for what they built or accept their interpretation of requirements.

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

    **Test coverage:**
    - Do tests exist for new functionality?
    - Do tests verify behavior (not just that code runs)?
    - Are edge cases covered?
    - Do all tests pass? (Run the test commands from the plan)

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

    ## Report Format

    **Per-task verdict:**
    - Task N: ✅ APPROVED | ❌ ISSUES: [specific problems with file:line references]

    **Overall phase verdict:**
    - APPROVED — All tasks pass, phase is shippable
    - ISSUES_FOUND — [list of all issues by task, with specific file:line references and what needs to change]

    Be specific. Vague feedback wastes time. "Missing validation" is bad. "applyTagSchema in tags.ts:15 does not validate that tagId is a valid UUID format" is good.
```
