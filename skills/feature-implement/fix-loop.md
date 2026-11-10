# Fix Loop and Breaker

Read from SKILL.md Step 4d, before a fix dispatch whenever this file is not in your context (the first round of a phase, and again after a compaction). Critical and Important findings that survived triage (4c) enter this loop. `<plugin lib>` is the path SKILL.md resolves.

A round is one fix dispatch plus one scoped re-review. Five rounds maximum per phase.

## Who fixes

- **Round 1 — resume the implementer that owns the finding.** Its context is intact: it knows the task, the code, and its own choices. Send the open findings verbatim, scoped to its task. If the harness cannot resume a completed subagent, dispatch fresh as in round 2.
- **Rounds 2–5 — fresh implementer.** A resumed context grows by a whole transcript per round and carries the last round's stale hypotheses, while each round usually chases a different root cause (one run's implementer grew from 194k to 430k tokens over three resumed rounds). Dispatch with the task text, the open findings verbatim, and the rounds summary below; it reads the current code itself. Frame it: "A prior implementer attempted this fix N times; you own it now." Rounds 4–5 go one tier up: a loop that survives three rounds usually needs more capability, not more context.
- **A finding about a rule** — an invariant, a boundary, a format, a requirement's wording — is fixed everywhere the rule is stated or applied, not only at the cited line: say so in the fix dispatch, next to the finding. A rule fixed in the code but still stated the old way in a test, a doc or the tech-spec comes back NOT ADDRESSED and costs a whole extra round.
- A parallel task's or a concurrent phase's worktree was merged and removed at 4a: every fix implementer works from your checkout, since fixes are sequential.
- Never fix findings yourself (SKILL.md Constraints): your context stays clean for coordination.

## Every round ends with a scoped re-review

Dispatch `./re-review-prompt.md` fresh every round — never a resumed re-reviewer and never a full phase re-review. A resumed reviewer carries every earlier round's transcript (one reached 251k tokens), and the rounds summary carries all it needs from them.

1. Record `FIX_BASE` (the HEAD the previous review saw) and log `Fix base (Phase N, round R): <sha>`.
2. Build the fix-diff package: `"<plugin lib>/review-diff.sh" "$FIX_BASE" "$STATE/phase-N-fix-R.diff"`.
3. Dispatch with the open findings list, the fix implementer's Decisions I made, and the rounds summary: one paragraph naming each earlier round's findings closed, your rulings on them, and approaches already rejected ("none" in round 1).

The re-reviewer verdicts each finding ADDRESSED / NOT ADDRESSED against the fix diff only, running just the checks each finding touches; the next barrier or milestone checkpoint runs the full suite over the fix. New Critical/Important breakage in the fix diff joins the open findings; out-of-scope observations go to the Execution Log as deferred minors — they never extend the loop.

## The breaker

When round 5's re-review still leaves findings open, stop dispatching and adjudicate each open finding yourself — you hold the plan and cross-phase context the reviewer lacks. Never a round 6.

- Reviewer wrong, or the point is contestable → `Parked (Phase N): <finding> — Ruling: <why the code stands>`
- Real, but nothing downstream builds on it → park the same way, with a ruling that says it is real and deferred
- Real and load-bearing (a later phase builds on it, or it reveals a plan defect) → rule on the smallest change that unblocks the dependent work, record the ruling, and carry it into the next phase's dispatch

Adjudicate only at the cap — adjudicating earlier to end a loop is pre-judging with a different name. Hard stops (SKILL.md, Rulings, Not Stalls) still go to the user.
