# Holistic Reviewer Prompt Template

Dispatch after ALL phases complete. Reviews the entire implementation as a whole.

```
Task tool (general-purpose):
  description: "Holistic review: [feature name] full implementation"
  model: "<premium-tier model>"      # e.g. Opus-tier; controller picks concrete model
  prompt: |
    You are doing a final holistic review of the complete [feature name] implementation.

    ## What Was Built

    [Summary of all phases and what each delivered]

    ## Spec and Acceptance Criteria

    [Full acceptance criteria from spec.md — paste inline]

    ## Diff Range

    Review only commits from BASE_SHA [sha] to HEAD [sha].

    ```bash
    git log [BASE_SHA]..[HEAD] --oneline
    git diff [BASE_SHA]..[HEAD] --stat
    ```

    Read the actual code changes. Do not rely on phase review summaries.

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

    **Acceptance criteria coverage:**
    - ✅ [criterion]: met
    - ❌ [criterion]: [what is missing]
    - ⚠️ [criterion]: [partially met, what is missing]

    **Integration issues (if any):**
    [specific file:line references]

    **Architecture deviations (if any):**
    [what was expected vs. what was built]

    **Overall verdict:**
    - READY TO MERGE — all criteria met, no blockers
    - NEEDS FIXES — [list of blockers with file:line references]
    - NEEDS DISCUSSION — [list of architectural concerns for human review]
```
