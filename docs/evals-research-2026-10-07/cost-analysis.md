# Where our eval money and time go (measured 2026-10-07)

Sources: `quality/baselines/v3.0.0.json`, `v3.1.0.json`, `quality/trend.jsonl`, 268 surviving run traces in `/private/tmp/e-*/out/trace.jsonl` (189 mapped to cases via `aggregate-result.json`). Token shares use list-price ratios: input 1, 1h cache write 2, cache read 0.1, output 5. On a Claude login the dollar figures are notional ("costBasis": "list"); what you really spend is usage-limit headroom.

## Per run
| | Sonnet | Haiku |
|---|---|---|
| mean cost / run | $0.19 | $0.05 |
| API calls / run | 6.2 | 5.7 |
| prompt on call 1 (system + tools + 45 skill descriptions + project instructions) | ~25k tokens | ~25k |
| of which read from cache on call 1 | ~6k | ~7k |
| share of cost: cache writes / cache reads / output | 62% / 16% / 11% | 44% / 20% / 11% |
| share of cost spent on call 1 alone | 37% | 45% |
| Skill call happens on call index | 0.24 (first call) | 1.1 |
| share of cost spent *after* the Skill call | 58% | 50% |

Findings:
1. **Cache writes are the bill.** Claude Code writes the cache with the 1-hour TTL (2x input price, vs 1.25x for 5-minute). A 5-minute TTL would cut ~30% (Sonnet) / ~25% (Haiku) — every run is shorter than 5 minutes.
2. **The 25k-token preamble is re-written every run.** Only ~6k of it hits cache across runs; the rest is rebuilt, likely because the random workspace path (`/private/tmp/e-XXXX/home/cwd`) and per-run env text sit early in the system prompt. If the prefix were shared, ~35–40% of cost disappears.
3. **Trigger cases pay for work nobody grades.** Sonnet fires the skill on its first call, then spends 40–65% more tokens executing it until `max_turns` (6). Orchestration cases spend ~70% after the Skill call — but they need it to reach the graded dispatch.

## Per release
| release | Sonnet | Haiku | previous tag re-run? |
|---|---|---|---|
| 2.8.0 – 2.12.0 | $6–10, 5–14 min | $2.5–3.9, 5–11 min | yes, every time (Claude Code version changed) |
| 3.0.0 | $14.69, 10 min | $5.01, 9 min | yes |
| 3.1.0 | $9.59, 7.5 min | $2.33, 3.7 min | no (stored baseline reused) |

- **A release usually costs double what the table shows**: Claude Code shipped a new patch (2.1.284→285→…→292) between nearly every release, and any CLI version change re-runs the whole previous tag. 3.0.0 ≈ $40 and ~40 min of wall time.
- **Everything runs serially**: HEAD Sonnet → HEAD Haiku → prev Sonnet → prev Haiku, each at concurrency 4 (`run.sh` uses `slots=1` in full mode).
- **Most expensive cases (Sonnet, 3 runs)**: the two planted-flaw reviews (~$0.55), trigger-new-feature ($0.55), nearmiss-skill-verify ($0.51), trigger-feature-verify ($0.48), trigger-doctor ($0.46). 11 of the 15 regression cases are routing (trigger/near-miss) cases at ~$0.13–0.18 a run.
- **Haiku gives little signal for its cost**: pass rate 24–30%, pass^k 0.1–0.25, report-only.
- **Wasted runs**: a 20000-entry plugin dir error (v3.0.0 first attempt, 75 Haiku runs errored), an offline run that burned 1100 s; dev iteration on single cases (7–12 runs per case while fixing feature-implement, ~$19 on 2026-10-06 alone).
- **Sonnet regression cases are saturated**: v3.1.0 mean 0.98, pass^k 1.0. Saturated cases still cost full price each release while rarely telling us anything.
