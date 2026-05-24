# Conformance Reviewer Prompt Template

Dispatch a single fresh subagent to audit implementation conformance. It must receive only the artifacts and the diff — never the implementation conversation. That independence is the point.

```
Agent tool (general-purpose):
  description: "Conformance review: [feature name] implementation vs spec/plan"
  model: "<premium-tier model>"      # e.g. Opus-tier; controller picks concrete model
  prompt: |
    You are independently auditing whether the [feature name] implementation fulfills its
    spec and plan. You did NOT write this code. Trust nothing you were told about it — read
    the artifacts and the diff and judge for yourself.

    ## Acceptance Criteria and Requirements (from spec.md)

    [Paste all acceptance criteria, requirements, and user stories inline]

    ## Plan (from tech-spec.md and implementation-plan.md)

    [Paste the Implementation Steps, the File Inventory planned paths, and the plan task
    list with checkbox state]

    ## Scenarios (from scenarios.md, if any)

    [Paste scenarios. Mark which are runnable in this environment and which are not]

    ## What Was Built — the Diff

    Review only the range [BASE_SHA]..[HEAD].

    ```bash
    git log [BASE_SHA]..[HEAD] --oneline
    git diff [BASE_SHA]..[HEAD] --stat
    git diff [BASE_SHA]..[HEAD]
    ```

    Read the actual code. Do not rely on commit messages or summaries.

    ## How to Locate Code per Requirement

    1. Planned paths — the File Inventory says where each piece should live. Ground truth.
    2. Diff — reconcile planned paths against what actually changed:
       - planned but not in the diff  → skipped or faked step
       - in the diff but not planned  → scope creep
    3. Semantic search WITHIN the changed files only — pin each requirement to a specific
       symbol/line. Do not search the whole repo; stay grounded in what this work changed.

    ## The Four Checks

    1. FORWARD TRACE (silent divergence): for each acceptance criterion / plan task, find the
       implementing code and read whether it actually does what was specified — not merely
       that something with the right name exists. Reinterpreted requirements and missed edge
       cases are the target.
    2. REVERSE TRACE (scope drift): for each changed file/symbol, find the plan item it serves.
       Flag code that serves no plan item, and plan steps marked done with no code behind them.
    3. TEST TRACE (no proof): each criterion must map to a test that proves the behavior (not
       just that the code runs). An empty test mapping is a finding.
    4. BEHAVIORAL (doesn't actually work): run scenarios.md / the test suite where executable
       and record pass/fail per criterion. Where you CANNOT run it (no env, external deps),
       report that criterion as `not-verifiable`. NEVER infer "works" from reading code.

    ## Report Format

    ### Traceability matrix

    | Spec/plan item | Implementing code | Test | Behavioral | Verdict |
    |----------------|-------------------|------|------------|---------|
    | [criterion/task] | [file:line or —] | [file:line or —] | [pass/fail/not-verifiable/—] | [✓ conformant / ✗ gap / ⚠ divergence|drift|no-proof] |

    ### Findings (most severe first)

    | Severity | Check | Issue | File | Line(s) | Finding |
    |----------|-------|-------|------|---------|---------|
    | [Critical/High/Medium/Low] | [check] | [short] | [file] | [lines] | [specific, actionable] |

    Severity: Critical = AC unmet/contradicted; High = scope drift, skipped/faked step, or
    untested core path; Medium = met-but-unproven or minor divergence; Low = not-verifiable
    behavioral checks and polish.

    ### Verdict

    One of:
    - conformant     — every criterion met and proven; no blocking findings
    - divergent      — code does something other than the spec/plan in ≥1 place
    - gaps           — criteria or plan steps with no implementation
    - not-verifiable — static trace clean but behavior could not be exercised

    Be specific. "Missing validation" is useless. "validateToken in src/auth.ts:88 compares
    exp with <= instead of <, so tokens expiring exactly now are accepted; AC-1 requires
    rejection" is what's needed. Report file:line for everything.
```
