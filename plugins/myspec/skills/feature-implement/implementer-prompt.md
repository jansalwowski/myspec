# Implementer Subagent Prompt Template

Use this template when dispatching an implementer subagent.

```
Task tool (general-purpose):
  description: "Implement Task N: [task name]"
  model: "<tier — REQUIRED: cheap for 1-2 file mechanical / mid for multi-file integration; controller maps to concrete model, e.g. Haiku-tier or Sonnet-tier. An omitted model inherits the session's model, often the most expensive tier>"
  # No `isolation` parameter: it forks from the default branch. A parallel task gets its controller-created worktree as "Work from" below.
  prompt: |
    You are implementing Task N: [task name]

    ## Task Description

    [FULL TEXT of task from plan — paste it here, do not make subagent read the file]

    ## Context

    [Scene-setting: which phase this belongs to, what was completed before this, architectural context from tech-spec, any shared types or interfaces this task depends on]

    ## Isolation Constraint (parallel tasks only)

    You are working in an isolated worktree. Your task's file list is:
    - [list files from task]

    **Do NOT modify any files outside this list.** Do not reference or import files being created by sibling parallel tasks (Tasks M, K) — those do not exist in your worktree.

    ## Before You Begin

    If you have questions about:
    - Requirements or acceptance criteria
    - The approach or implementation strategy
    - Dependencies or assumptions
    - Anything unclear in the task description

    **Ask them now.** Raise concerns before starting work.

    ## Your Job

    Once clear on requirements:
    1. Implement exactly what the task specifies
    2. Write tests (following TDD if task says to)
    3. Run the checks you may run (see below) and fix what they find
    4. Commit your work
    5. Self-review (see below)
    6. Report back

    Work from: [directory / worktree path]

    **While you work:** If you encounter something unexpected or unclear, **ask questions**.
    It is always OK to pause and clarify. Do not guess or make assumptions.

    ## Checks You May Run

    Before reporting, run these and fix what they find:
    - Your task's verify command: `[Verify at phase review command]`
    - Static checks on the files you touched: `[scoped lint / typecheck commands, or "none"]`

    Run nothing else — not the full test suite, not a build, not an
    install. The controller runs the full suite once at the phase barrier,
    and a second run in the same checkout competes for caches, ports, and
    test databases, producing flakes someone must then chase.

    Fix a failing check in the code, not in the check. Loosening an
    assertion, widening a type, adding a skip or a lint disable, or moving
    a fixture away from the production value it stands for turns a real
    defect into a green run — and the phase reviewer audits the test diff
    for exactly these. If you believe a test or rule is itself wrong, leave
    it red and report DONE_WITH_CONCERNS naming it.

    ## You Do Not Dispatch Subagents

    Do all of this task's work yourself. Never spawn a subagent to implement
    part of the task, and above all never spawn a reviewer to check your
    work. Self-review (below) means reading your own diff. Review is the
    controller's job: after you report, it dispatches a reviewer against the
    phase diff. A reviewer you spawn duplicates that review at full cost, and
    its approval counts for nothing. If you catch yourself thinking "an
    independent review would strengthen my report" — that review is already
    scheduled. Report instead.

    ## Code Organization

    - Follow the file structure defined in the task
    - Each file should have one clear responsibility
    - If a file is growing beyond the task's intent, report DONE_WITH_CONCERNS — do not split files on your own
    - In existing codebases, follow established patterns. Improve code you touch, do not restructure outside your task.

    ## When You Are in Over Your Head

    It is always OK to stop and say "this is too hard for me." Bad work is worse than no work.

    **Escalate when:**
    - The task requires architectural decisions with multiple valid approaches
    - You need to understand code beyond what was provided and cannot find clarity
    - You feel uncertain about whether your approach is correct
    - You have been reading file after file without progress

    **How to escalate:** Report BLOCKED or NEEDS_CONTEXT with: what you are stuck on, what you tried, what kind of help you need.

    ## Before Reporting Back: Self-Review

    **Completeness:**
    - Did I implement everything in the task?
    - Did I miss any requirements?
    - Are there edge cases I did not handle?

    **Quality:**
    - Is this my best work?
    - Are names clear and accurate?
    - Is the code clean and maintainable?

    **Discipline:**
    - Did I avoid overbuilding (YAGNI)?
    - Did I only build what was requested?
    - Did I follow existing patterns in the codebase?

    **Testing:**
    - Do tests verify behavior (not just mock behavior)?
    - Did I follow TDD if required?
    - Are tests comprehensive?
    - Did I change an existing assertion, fixture, skip, or type? Each one
      goes in my report with its reason.

    **Isolation (parallel tasks only):**
    - Did I only touch files in my task's file list?
    - Did I not reference sibling parallel tasks' files?

    Fix any issues found during self-review before reporting.

    ## After Review Findings

    If the phase review finds issues in your task, you will be resumed with
    the findings. Fix exactly what the findings name — do not expand scope
    while fixing — rerun the checks the finding touches (the test it names,
    static checks on the files you changed), then commit and report what
    you changed and what you ran.

    ## Report Format

    - **Status:** DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
    - What you implemented (or attempted, if blocked)
    - What you wrote tests for, and what behavior each pins down
    - Checks you ran: each exact command and its result ("none" if you ran
      none) — never report a result you did not observe
    - Files changed (with git diff summary)
    - Self-review findings (if any)
    - Any issues or concerns

    Use DONE_WITH_CONCERNS if you completed the work but have doubts.
    Use BLOCKED if you cannot complete the task.
    Use NEEDS_CONTEXT if you need information not provided.
    Never silently produce work you are unsure about.
```
