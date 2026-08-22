# Holistic Reviewer Prompt Template

Dispatch after ALL phases complete. Reviews the entire implementation as a whole.

Before dispatching, write the full-feature review package to one file and substitute its path below — same shape as the phase review package, over `BASE_SHA..HEAD`:

```bash
PKG=$(mktemp "${TMPDIR:-/tmp}/holistic-review.XXXXXX")
{ git log --oneline "$BASE_SHA"..HEAD; echo; git diff --stat "$BASE_SHA"..HEAD; echo; git diff -U10 "$BASE_SHA"..HEAD; } > "$PKG"
```

`BASE_SHA` is the sha recorded in Step 2 before any implementation — never `HEAD~1`. Also paste in the plan's Execution Log entries (deferred minors and parked findings) — this reviewer is where they get triaged; a roll-up nobody reads is a silent discard.

```
Task tool (general-purpose):
  description: "Holistic review: [feature name] full implementation"
  model: "<premium tier — REQUIRED; e.g. Opus-tier; controller picks concrete model. An omitted model inherits the session's model — never assume it is premium>"
  prompt: |
    You are doing a final holistic review of the complete [feature name] implementation.

    ## What Was Built

    [Summary of all phases and what each delivered]

    ## Spec and Acceptance Criteria

    [Full acceptance criteria from spec.md — paste inline]

    ## Diff Under Review

    **Base:** [BASE_SHA]  **Head:** [HEAD sha]
    **Package file:** [PKG path]

    Read the package file once — it contains the branch's commit list, a
    stat summary, and the full diff with surrounding context. It is your
    view of the change; do not rebuild it with git commands. If the file is
    missing, fetch the diff yourself: `git log --oneline`,
    `git diff --stat`, and `git diff -U10` over [BASE_SHA]..[HEAD sha].
    Read the actual code changes. Do not rely on phase review summaries.

    Your review is read-only on this checkout, except for running the
    verification commands from the plan. Never edit files or mutate the
    index, HEAD, or branch state.

    ## You Do Not Dispatch Subagents

    Do all of this review yourself. Never spawn a subagent to review part of
    the diff, and never spawn another reviewer for a second opinion. This
    process already provides every review seat the work gets; a reviewer you
    spawn duplicates one of them at full cost, and its verdict counts for
    nothing. If the diff feels too large for one pass, review it in passes
    yourself and say so in your report.

    ## Deferred Minors and Parked Findings

    The controller parked these during execution; you are their triage:

    [Execution Log entries — every `Deferred minor` and `Parked` line, pasted verbatim]

    For each: decide whether it must be fixed before merge or can ship as
    recorded. A parked finding carries the controller's ruling — weigh the
    ruling, but judge the code on its merits; a recorded rationale never
    downgrades a finding's severity.

    ## Your Job

    **Cross-phase integration:**
    - Do the pieces fit together? Do phase outputs compose correctly?
    - Are there integration gaps between phases?
    - Are any shared types, interfaces, or utilities inconsistent across phases?

    **Acceptance criteria:**
    - Is every acceptance criterion from the spec met?
    - Are there criteria that were partially met or missed entirely?

    **Architecture coherence:**
    - Does the implementation follow the approach described in the tech-spec?
    - Are there architectural deviations that weren't justified?
    - Is the code organized consistently across phases?

    **Test coverage (overall):**
    - Is the feature's critical path tested end-to-end?
    - Are there gaps in test coverage at integration points?

    **Readiness:**
    - Is the implementation ready to merge?
    - Are there any blockers?

    ## Report Format

    Your final message is the report itself: begin directly with the first
    acceptance criterion's verdict. Every line is a verdict, a finding with
    file:line, or a check you ran — no preamble, no process narration.

    **Acceptance criteria coverage:**
    - ✅ [criterion]: met
    - ❌ [criterion]: [what is missing]
    - ⚠️ [criterion]: [partially met, what is missing]

    **Integration issues (if any):**
    [specific file:line references]

    **Architecture deviations (if any):**
    [what was expected vs. what was built]

    **Deferred-minors triage:**
    - [entry]: MUST FIX before merge | SHIPS AS RECORDED — [one-line reason]

    **Overall verdict:**
    - READY TO MERGE — all criteria met, no blockers, no MUST FIX triage items
    - NEEDS FIXES — [list of blockers with file:line references]
    - NEEDS DISCUSSION — [list of architectural concerns for human review]
```
