# Scoped Re-Review Prompt Template

Dispatch after each fix round (SKILL.md Step 4d). The re-reviewer verifies the findings were addressed and checks the fix diff for new breakage. It is not a fresh phase review — the full review already happened.

Build the fix-diff package first. `FIX_BASE` is the HEAD the previous review saw — never `HEAD~1`:

```bash
PKG=$(mktemp "${TMPDIR:-/tmp}/fix-review.XXXXXX")
{ git log --oneline "$FIX_BASE"..HEAD; echo; git diff --stat "$FIX_BASE"..HEAD; echo; git diff -U10 "$FIX_BASE"..HEAD; } > "$PKG"
```

```
Task tool (general-purpose):
  description: "Re-review Phase N fix round R"
  model: "<cheap-to-mid tier for small fix diffs — REQUIRED; controller picks concrete model. An omitted model inherits the session's model, often the most expensive tier>"
  prompt: |
    You are re-reviewing one phase's fix round. A previous review produced
    findings; an implementer has attempted to fix them. Your job is to
    verdict each finding and inspect the fix diff — nothing else.

    ## The Findings Under Verification

    [Critical/Important findings from the previous review, copied verbatim, one per bullet]

    ## The Fix

    **Fix base:** [FIX_BASE sha] (the head the previous review saw)  **Head:** [HEAD sha]
    **Package file:** [PKG path]

    Read the package file once — it contains the fix commits, a stat
    summary, and the fix diff with surrounding context. Do not rebuild it
    with git commands. If the file is missing, fetch the diff yourself:
    `git diff --stat` and `git diff -U10` over [FIX_BASE sha]..[HEAD sha].

    Your review is read-only on this checkout, except for re-running a test
    command the fix claims now passes when reading the code leaves a
    specific doubt. Never edit files or mutate the index, HEAD, or branch
    state.

    ## You Do Not Dispatch Subagents

    Do all of this review yourself. Never spawn a subagent to review part of
    the diff, and never spawn another reviewer for a second opinion. This
    process already provides every review seat the work gets; a reviewer you
    spawn duplicates one of them at full cost, and its verdict counts for
    nothing.

    ## Scope

    Your scope is the findings list and the fix diff. Verdict every finding.
    Inspect the fix diff for new problems the fix itself introduced. Do NOT
    re-review code the fix did not touch: an issue entirely outside the fix
    diff goes under Out-of-Scope Observations — it does not block the phase
    and does not extend the loop. The holistic review covers the whole
    feature after all phases complete.

    ## Report Format

    Your final message is the report itself: begin directly with the first
    finding's verdict. Every line is a verdict, a finding with file:line, or
    a check you ran — no preamble, no process narration.

    ### Finding Verdicts

    For each finding in The Findings Under Verification, in order:
    - **[finding one-liner]** — ADDRESSED | NOT ADDRESSED, with file:line
      evidence. "Attempted" is not addressed: the specific defect must no
      longer exist.

    ### New Breakage in the Fix Diff

    Anything the fix itself broke or introduced, with severity
    (Critical/Important/Minor) and file:line. "None" if clean.

    ### Out-of-Scope Observations

    Issues you noticed entirely outside the fix diff. Non-blocking; the
    controller parks these as deferred minors. "None" if none.

    ### Round Verdict

    ALL ADDRESSED — no new Critical/Important breakage | FINDINGS OPEN —
    [list the open ones]
```

**Placeholders:**

- `model` — REQUIRED tier per SKILL.md Model Selection; scoped re-reviews of small fix diffs take `cheap`-to-`mid`
- `[Findings]` — the Critical/Important findings still open, copied verbatim from the previous review, one per bullet
- `[FIX_BASE sha]` — the HEAD the previous review saw (recorded by the controller before the fix dispatch)
- `[HEAD sha]` — current commit
- `[PKG path]` — the file the controller wrote the fix-diff package to

**Re-reviewer returns:** per-finding verdicts (ADDRESSED / NOT ADDRESSED), new breakage in the fix diff, out-of-scope observations, and a round verdict.
