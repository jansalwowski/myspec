# Testing Skills

Methodology for skill-verify step 16. A static audit cannot tell whether a skill activates or whether its guidance changes behavior — only a run can. Recommend these by name and size; a vague "test your triggers" suggestion gets ignored.

## Trigger test (does it fire?)

No native tooling covers this. `claude plugin eval` tests behavior *after* invocation and cannot score activation.

- **~20 queries**: 8-10 that should trigger, 8-10 that should not
- **3 runs per query**; compute a trigger rate across runs
- **Negatives must be near-misses.** "Write a fibonacci function" against a PDF skill tests nothing. Use queries that plausibly sit just outside the boundary.
- **Write queries the way users type**: real file paths, typos, casual phrasing, a sentence of backstory
- **Split 60/40** into train and validation, fixed across iterations, with a proportional mix of positives and negatives in each
- **Iterate about five times**, then **select the iteration with the best validation rate** — the best description is often not the last one written
- Target 80-90% correct activation

One caveat that invalidates test cases: agents consult skills for tasks beyond what they can already do. "Read this PDF" will not trigger a PDF skill however good the description is, because the agent can already read PDFs. Test cases must need the skill.

**Diagnostic with no harness:** ask a fresh agent "when would you use the {name} skill?" and compare the answer to the intended trigger. A wrong answer here predicts a wrong activation.

## Behavior test (does it help?)

`claude plugin eval` runs cases with and without the plugin loaded and scores the delta.

- Suite layout: `evals/<case>/prompt.md` plus `graders/*.md`; grader types include regex, tool_used, tool_order, file_exists, and llm-judge
- **Start with 2-3 cases**, expand later
- **Write assertions after the first run.** What "good" looks like is usually not knowable until the skill has run once.
- **Delete assertions that pass in both arms.** They inflate the with-skill score without measuring the skill.
- Investigate assertions failing in both arms — usually the task, not the skill
- Grade PASS/FAIL with quoted evidence; do not give the benefit of the doubt
- Read execution transcripts, not just final outputs
- Gate CI on `--threshold`; it exits non-zero below the bar

## Wording micro-test (does this specific guidance land?)

Run when a fix rewrote behavior-shaping guidance — a form change, a guard-content cut, a prohibition rewritten as a recipe.

1. **Run a no-guidance control first.** If the control does not exhibit the failure, the guidance is dead weight — delete it rather than reword it.
2. **5+ fresh-context reps per variant.** Single samples lie.
3. **Read every flagged match manually.** Template echoes masquerade as hits.
4. **Treat variance as a metric.** When guidance lands, reps converge on the same shape; a noisy spread means it did not.

## When a test fails

Prefer simplifying the skill over adding rules to it. An over-complex skill lowers its own hit rate, and a failing eval is more often a sign of too much instruction than too little.
