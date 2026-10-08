# Evals: a primer, and what it means for myspec

Read this first. Deep dives with every source cited:
- [`external.md`](external.md): theory, statistics and cost techniques (Anthropic, OpenAI, Hamel Husain, Eugene Yan, τ-bench, UK AISI)
- [`plugin-eval.md`](plugin-eval.md): how `claude plugin eval` works (flags, schema, graders, caching, ablation)
- [`cost-analysis.md`](cost-analysis.md): where our money and time actually go, measured from our baselines and 268 run traces

---

## 1. What an eval is

An eval is a test for behaviour that isn't deterministic. A unit test runs the same code and gets the same result. An eval gives a model a realistic input and checks what it did. The model answers differently each time, so a single eval result is a sample, not a fact.

| Term | Meaning | In our suite |
|---|---|---|
| **Task / case** | one scenario: input plus success criteria | `evals/<case>/` (prompt.md, fixture.sh, graders/) |
| **Trial / run** | one attempt at a case | `runs: 3` means 3 trials |
| **Grader** | the code or judge that scores one aspect | `graders/*.md` |
| **Transcript / trace** | the full record of a run: tool calls, messages | `trace.jsonl` |
| **Outcome** | the final state of the world (files written, etc.) | `file_exists`, regex over files |
| **Harness** | the runner | `claude plugin eval`, wrapped by `scripts/evals/run.sh` |

### Three kinds of grader
- **Code graders** (regex, `tool_used`, `file_exists`, `tool_order`) are free, fast and reproducible, but brittle. We use them everywhere.
- **Model graders** (an LLM judge) handle open-ended output, but they are noisy, cost money, and must be checked against a human's verdict. We pin the judge to Sonnet because Haiku gave false FAILs.
- **Human review** is the gold standard and the slowest. It means reading transcripts, which every source says matters most.

### Two kinds of eval, asking different questions
- **Regression evals** ask "does it still work?". They should pass about 100% of the time, so a failure is news. 15 of our cases are `regression`.
- **Capability evals** ask "how good is it?". They are allowed to fail, and the failure rate is the measurement. 10 of our cases are `capability`.
- A capability case that becomes reliable *graduates* to regression. We do this already (feature-plan-gate, trigger-memorize).

### pass@k and pass^k
- **pass@k**: at least one of k tries succeeded ("can it ever do this?").
- **pass^k**: all k tries succeeded ("can it be trusted to do this?").
- For a skill a user invokes once, pass^k is the honest number. At a true 90% success rate, a case still fails at least one of 3 runs **27% of the time**. One red run on one case is usually noise.

### What our suite tests (four families)
1. **Trigger / near-miss**: does the right skill fire on a natural prompt, and its sibling stay quiet? This is routing, decided by the skill descriptions.
2. **Planted flaw**: give a review skill a document with known defects. Does it find them?
3. **Artifact contract**: does the written file have the shape the next skill reads?
4. **Orchestration**: does feature-implement dispatch the right subagent with the right instructions?

## 2. Statistics in one page

- **Noise is the enemy.** Each case is a coin weighted by the model's reliability. More runs per case narrows that case's estimate. More *cases* narrows the suite estimate. Anthropic's "Adding error bars to evals" paper finds that extra trials hit diminishing returns quickly, while extra cases keep paying.
- **Paired comparison.** Compare the same case on the old and the new release (`compare.mjs` does this). Pairing cancels out case difficulty, which is far more powerful than comparing two averages.
- **What 25 cases can detect:** only a mean drop of about 11–22 points. A sign test needs 6 or more cases flipping the same way before it reaches p < 0.05. So the release gate is a **smoke alarm for big breaks**, not a precision instrument. That's fine, as long as we price it that way.
- **Sequential / adaptive testing.** Stop early once the answer is clear: run once, and add runs only on failure or ambiguity. UK AISI's Bayesian stopping cut 57–97% of trials and reached the same conclusions.
- **Errored runs are not failures.** A rate limit or a timeout scores 0. Our `summary.mjs` already drops those runs.

## 3. Pitfalls (and where we stand)

| Pitfall | Us |
|---|---|
| A grader that can't fail | handled: `grader-samples.json`, `check-graders.mjs` |
| A judge used without calibration | avoided: deterministic graders first, judge pinned |
| Saturation: cases that always pass and cost full price | **yes**: Sonnet regression cases at mean 0.98, pass^k 1.0 |
| Over-reading noise on single cases | mitigated: regressed = all → none, or Δ ≥ 0.67 |
| Paying for work nobody grades | **yes**: see §4 |
| Not reading transcripts | unknown; the friction notes in README suggest you do |

## 4. Where our cost goes (measured)

A Sonnet run costs about **$0.19** and a Haiku run about **$0.05**. A release costs **$12–20 for HEAD, and usually the same again** to re-run the previous tag, because Claude Code shipped a new patch before 7 of our 8 releases. That makes 3.0.0 about **$40 and ~40 minutes**. (On a Claude login these dollars are notional: they come out of your usage limits.)

| Where the tokens go | Share of a Sonnet run |
|---|---|
| Writing the prompt cache (1-hour TTL, billed at 2x input) | **62%** |
| The first API call alone: a ~25k-token preamble, of which only ~6k is cached across runs | **37%** |
| Everything after the Skill call fires, in trigger cases (which grade only the Skill call, plus sometimes a file) | **40–65%** |

Time: everything runs in series (HEAD Sonnet, then HEAD Haiku, then prev Sonnet, then prev Haiku), 4 runs at a time.

## 5. Candidate improvements (proposals as of 2026-10-07; see §6 for what happened)

Ranked by expected saving. Each needs a small experiment before we commit to it.

| # | Idea | Est. saving | Risk / unknown |
|---|---|---|---|
| 1 | **Shorter cache TTL**: run with `CLAUDE_CODE_PROMPT_CACHE_TTL` set to 5 minutes (documented). Every run is shorter than 5 minutes. | ~25–30% of every run | Unverified whether `plugin eval` passes the variable to its child sessions. One $0.20 run settles it (check `ephemeral_5m` in the trace). |
| 2 | **Don't re-run the previous tag on every CLI patch**: re-run only once its baseline is older than N releases or the minor version changes (`--cc-match minor` exists). | up to ~50% of release cost | A CLI patch *can* move triggering. Trade some rigour for half the bill. |
| 3 | **Cheap trigger harness**: for routing cases, stop the session at the first tool call, as Anthropic's skill-creator `run_eval.py` does. | 40–65% of 11 of the 15 regression cases | Needs a wrapper outside `plugin eval`. Cases that also check a written file stay as they are. |
| 4 | **Adaptive runs**: 1 run per saturated regression case, plus 2 more only if it fails. | ~2/3 of regression runs, almost all of which pass | The statistics in `compare.mjs` assume k = 3; pass^k would need adjusting. |
| 5 | **Haiku**: cut it, run it less often (every other release), or move it to the current Haiku. The `haiku` alias resolved to `claude-haiku-4-5`. | ~20% of release cost | Report-only today, with a 24–30% pass rate: it tells us little per dollar. |
| 6 | **Parallelise models and sides** (HEAD and prev, Sonnet and Haiku), and raise concurrency from 4 toward 8. | wall time ÷2–4, no cost change | Rate limits on one login. Errored runs are already excluded. |
| 7 | **Preflight before spending**: catch known infrastructure failures (the 20000-entry directory, offline) before launching any run. | wasted runs (v3.0.0's first attempt) | Cheap. Partly done already. |
| 8 | **Share the 25k-token preamble across runs** (`--exclude-dynamic-system-prompt-sections`). | ~35–40% | Probably not reachable: `plugin eval` builds its own command line, and each run gets a random workspace path. |

Ideas 1 and 2 alone would cut a typical release from about $25–30 to about $10, with no change to any case.

## 6. Outcome (2026-10-08)

| # | Result | Evidence |
|---|---|---|
| 1 | **Done** (#338). `run.sh` defaults `CLAUDE_CODE_PROMPT_CACHE_TTL=5m` | The variable reaches the eval sessions: every cache write was `ephemeral_5m`, and one Sonnet run cost $0.058 against $0.073–0.102 |
| 2 | **Done** (#339). `--cc-match minor` is the default | Six past re-runs of the same plugin on the next CLI patch moved 0 of 110 Sonnet and 0 of 110 Haiku case pairs by ≥ 0.34 |
| 3 | **Done, in a cheaper form** (#340). The ten routing cases graded only on Skill calls cap at `max_turns: 2`; no wrapper needed | Sonnet passed 30/30 runs with no sibling fired, and cost 27% less for those cases. Every Skill call in the stored traces was on turn 1 |
| 4 | Open | Needs `compare.mjs` statistics redone; not provable cheaply |
| 5 | **Solved upstream.** Claude Code 2.1.294 resolves `haiku` to `claude-haiku-5-5`, about 10x cheaper | On the routing cases, 32/51 runs passed against 11/41 on 4.5, at about $0.005 a run. Still far below Sonnet, so it stays report-only |
| 6 | Concurrency 8: **rejected**. Parallel models: open | 4 subset cases × 3 runs took 53 s at concurrency 4 and 54 s at 8. Running models in parallel would need the cost ceiling redesigned |
| 7, 8 | Not pursued | |

Estimate for a typical release that follows a CLI patch: about $24 before, about $7 after. This is combined from the separate measurements above, not from one measured full run.
