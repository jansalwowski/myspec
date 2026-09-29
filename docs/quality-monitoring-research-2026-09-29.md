# Quality monitoring for myspec — research (2026-09-29)

This is input for a brainstorm. The question: how can we measure the quality, predictability and performance of myspec itself, how do other frameworks do it, and what exactly could we build?

## 0. Summary

- Claude Code 2.1.284 has a built-in eval runner, `claude plugin eval`. **A real pilot on a copy of myspec cost $1.17 and took under 3 minutes.** It works once the aiDir files are scaffolded, and it already found two real problems (§3.3).
- Only about 40% of myspec's past regressions need a model eval. The rest are cheaper to catch with deterministic tests or static lint (§4). So the plan has layers; it is not only an eval suite.
- Most SDD frameworks (Spec Kit, BMAD, OpenSpec, Kiro, Agent OS) have **no behavioural evals**. Only superpowers, Anthropic's skill-creator and Tessl test what their skills do (§2).
- Telemetry can stay entirely local: friction-scan already parses transcripts and only needs to keep what it finds (§5.4).

## 1. Where myspec stands

| Area | Today |
|---|---|
| Deterministic tests | 20 bash suites (`lib/tests`, `hooks/tests`, ~5k lines) in `test.yml`, covering helper libs and hooks |
| Static checks | `setup-doctor.mjs` (wiring, token budget), `check-no-localhost-ports.sh`, `sync-check.yml` for the mirror. `skill-verify` is LLM-run, manual, and not in CI |
| Behavioural evals | **None.** `skills/skill-verify/references/testing-skills.md` recommends `plugin eval` to downstream users, but the repo doesn't use it on itself |
| Runtime signal | `lib/friction-scan/scan.mjs` finds hook blocks, BLOCKED subagents, fix rounds and slow subagents per session. It prints the result and **persists nothing** |
| Release gate | Clean tree, mirrors identical, `bash -n`, last CI green. No quality gate |
| Trend | fix/feat ratio went from 1.3 (all time) to 1.8 (3 months) to **2.1 (September: 44/21)**. 12 tags in September; 1 `test(` commit ever |

## 2. How others do it, with verbatim examples

| Framework | Behavioural evals | What they have |
|---|---|---|
| GitHub Spec Kit | No | pytest for the CLI, template contract tests |
| AWS Kiro | No (public) | Anecdotal speed claims |
| BMAD-METHOD | No | `validate_skills.py`: 10 deterministic rules, plus an LLM validator prompt |
| OpenSpec | No | vitest, opt-out PostHog command counts, `/feedback` that files a GitHub issue |
| Agent OS | No | Nothing |
| **Tessl** | Yes | Skill review score with a CI `--threshold`; task evals with and without the skill, graded on a weighted rubric; repo evals that replay real commits |
| **obra/superpowers** | Yes | ~60 live "Quorum" scenarios: a simulated user, an LLM assessor and deterministic post-checks. Live runs are nightly or manual; PR CI is static only |
| **Anthropic skill-creator** | Yes | Compares against no skill or the **previous skill version**; mean ± stddev; flags weak assertions; tunes descriptions for triggering |

### 2.1 superpowers: one scenario per folder, the same fact asserted twice

Layout is `scenarios/<name>/{story.md, setup.sh, checks.sh, checks-manifest.json}`. The simulated user never sees the acceptance criteria. A run passes only when **both** the LLM assessor and every deterministic check pass. ([planted-flaw scenario](https://github.com/prime-radiant-inc/superpowers-evals/tree/main/scenarios/spec-reviewer-catches-planted-flaws))

```
Do NOT name the planted flaws. Do NOT volunteer hints about completeness …
## Acceptance Criteria
- The agent dispatched a reviewer subagent — an `Agent` tool call appears in the session log.
- The reviewer flagged the literal TODO in the Requirements section …
- The reviewer's status is "Issues Found" or equivalent … A reviewer that returns
  "Approved" while also listing issues elsewhere also fails — the verdict must match the findings.
```
```bash
pre()  { file-contains docs/superpowers/specs/test-feature-design.md 'TODO: Add more requirements here'; }
post() { check-transcript tool-called Agent; }
```

- `pre()` checks that the planted flaw really is in the fixture before the run starts.
- A `checks-manifest.json` lists the checks each run must emit. If the emitted checks don't match, the run is graded *indeterminate* instead of passing vacuously.
- Cost scenarios (`cost-spec-plan-duplication`, `cost-trivial-task-review-fanout` with `tool-count Agent lte 2`) are measurement tools: they compare total tokens and doc bytes against a control run rather than enforcing a dollar cap.
- Results are written up as documents: n per arm, a table of verbatim quotes, the exact prompt, and an honest Limitations section ("Five reps per cell is a smoke-strength signal"). [example](https://github.com/obra/superpowers/blob/main/docs/superpowers/specs/2026-07-06-sdd-plan-scoped-workspace-eval-results.md)

### 2.2 skill-creator: compare against the previous version, and critique the graders

The baseline is the previous skill version (`old_skill/`) when editing a skill, or no skill for a new one. `aggregate_benchmark.py` produces:

```json
"delta": {"pass_rate": "+0.50", "time_seconds": "+13.0", "tokens": "+1700"},
"notes": ["Assertion 'Output is a PDF file' passes 100% in both configurations - may not differentiate skill value",
          "Eval 3 shows high variance (50% ± 40%) - may be flaky or model-dependent"]
```

The grader prompt ([grader.md](https://github.com/anthropics/skills/blob/main/skills/skill-creator/agents/grader.md)) also grades the evals themselves: *"A passing grade on a weak assertion is worse than useless."*

Trigger evals are `[{"query", "should_trigger"}]` built around **near-misses**. Each query runs 3 times; a skill counts as triggering at a rate of 0.5 or more. When tuning a description, the queries are split 60/40 into train and held-out sets.

### 2.3 Tessl: a weighted-checklist rubric

```json
{ "type": "weighted_checklist",
  "checklist": [{ "name": "fixes_syntax_error", "description": "…", "max_score": 1, "category": "INTENT" }] }
```

- Categories are `INTENT`, `DESIGN`, `MUST_NOT`, `MINIMALITY`, `REUSE`, `INTEGRATION` and `EDGE_CASE`, with partial credit. Real rubrics put most of the weight on what the skill teaches (60/20/…/3).
- Repo evals: `tessl scenario generate org/repo --commits abc123` rebuilds a task and rubric from a real diff.
- The docs warn: *"If the 'with context' score sits at zero improvement … the skill most likely never activated."* The pilot hit exactly this (§3.3).

### 2.4 BMAD: static rules to compare with ours

`validate_skills.py --strict` checks:
- SKILL.md exists
- `name` and `description` are non-empty
- the name matches the directory
- the description is ≤1024 chars and **contains "Use when"**
- the body is not empty
- there are no time estimates

An LLM validator prompt covers the rules that need judgement: "a menu must HALT", no "skip to step", every file reference resolves, and a cross-skill reference must say "Invoke the `x` skill".

### 2.5 promptfoo: recall scoring for review skills

The Claude Agent SDK provider (`plugins: [{type: local, path: …}]`) supports these assertions: `skill-used`, `not-skill-used`, a JS assertion computing recall over `expectedIssues`, `cost < 0.50`, `latency < 120000`, weighted `max-score`, and `--repeat 3`. This is the fallback if `plugin eval` isn't expressive enough, because it allows custom code graders. [guide](https://www.promptfoo.dev/docs/guides/test-agent-skills/)

### 2.6 Anthropic's task shape and roadmap

[Demystifying evals](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents) shows a task definition that combines graders (`deterministic_tests`, `llm_rubric`, `static_analysis`, `state_check`, `tool_calls`) with `tracked_metrics` (`n_turns`, `n_toolcalls`, `n_total_tokens`, latency). Its roadmap:
- Start with 20–50 tasks taken from real failures.
- Write tasks that two experts would grade the same way.
- Balance should-trigger and shouldn't-trigger cases.
- Read the transcripts.
- Keep capability evals (low pass rate) separate from regression evals (~100%).
- Grade what the agent produced, not the path it took.

Published evidence on SDD itself is thin:
- **Böckeler** (martinfowler.com): agents often don't follow instructions; no numbers.
- **Uvik** (vendor, one team): 80–84% merge rate with a spec vs 72% without; the difference shows only on multi-file features.
- **arXiv 2606.30689**: measures determinism as lexical similarity between sessions; mandatory citations lower determinism but make ~87% of hallucinations detectable.
- **Spec Kit Agents** (arXiv 2604.05278): +0.15 on a 1–5 judge scale.
- No framework collects quality telemetry from real users.

## 3. `claude plugin eval`: reference and pilot

### 3.1 Case format (verified against 2.1.284 and the [docs](https://code.claude.com/docs/en/plugin-evals))

```
evals/<case>/prompt.md       frontmatter: name, description, tags, runs(3), model, max_turns(10),
                             timeout_seconds(300), allowed_tools, append_system_prompt, env(EVAL_*)
evals/<case>/graders/*.md    one grader per file: type, weight, arm (+ type fields)
evals/<case>/case.yaml       schema_version "1.1"; context.scaffold_script (runs with --scaffold),
                             context.history_file (resume a transcript), context.add_dirs (read-only fixtures)
```

**Graders:**
- Free: `regex` (target: last_message | trace | files), `tool_used` (`input_match`, `min`/`max`), `tool_order`, `file_exists` (only files created during the run count).
- Paid: `llm` (2-of-3 judge votes), `baseline`.
- There are no custom-code graders.

**Arms:**
- By default every case also runs without the plugin, and the report shows the difference (Δ).
- In that two-arm mode, `tool_used: Skill` graders become *unscored* "plugin-fired indicators".

**Output:** `aggregate-result.json`. Per run it records `score`, `turns`, `costUsd`, `durationSeconds`, and each grader's `passed`/`judgeVotes`.

**Exit codes:** 0 all cases met `--threshold`; 1 below threshold; 2 cost cap hit or auth failure.

### 3.2 Pilot cases (in the scratchpad pilot dir, not in the repo)

The scaffold script writes `.myspec.json` (`aiDir: ".ai"`), a CLAUDE.md with the `myspec:paths` binding, and `index.yaml`. Cases b and c also get a fixture `invoice-export/spec.md` with three planted defects:
- **AC-2:** "The export should be fast" (untestable).
- **REQ-002 vs REQ-004:** "every invoice regardless of status" vs "Draft invoices must never appear" (contradiction).
- **No error states:** nothing for a failed export, an empty range or an invalid range.

```markdown
# evals/review-planted-flaws/prompt.md
---
description: feature-spec-review must fire and flag all three planted defects.
max_turns: 8
timeout_seconds: 240
allowed_tools: [Read, Glob, Grep, Skill]
---
Please review the invoice-export spec in .ai/features/invoice-export/ and list every problem you find. Don't change any files.
```
```markdown
# graders/flags-contradiction.md
---
type: regex
pattern: '(REQ-00?2[\s\S]{0,400}REQ-00?4|REQ-00?4[\s\S]{0,400}REQ-00?2)'
---
# graders/skill-fired.md
---
type: tool_used
tool: Skill
input_match: '"skill"\s*:\s*"(?:[\w-]+:)?feature-spec-review"'
---
# graders/flags-missing-error-state.md
---
type: llm
---
PASS if the review points out that the spec does not define what happens when the export cannot
produce a normal file: a failed export or error, a date range with no invoices, or an invalid range.
```

### 3.3 Pilot results (sonnet, `--runs 2 --concurrency 2`, $0.91, 149 s)

| Case | With | Without | Δ | Skill fired |
|---|---|---|---|---|
| trigger-new-feature ("start a new feature: CSV export") | 1.00 | 0.00 | +1.00 | 2/2 |
| route-spec-review ("before tech design, check the requirements doc") | 1.00 | 0.50 | +0.50 | 2/2 right, 0 wrong |
| review-planted-flaws ("review the spec, list every problem") | 0.83 | 1.00 | **−0.17** | **1/2** (1/4 across all runs) |

**Findings:**
1. **feature-spec-review under-triggers on the most natural phrasing.** Claude usually reviewed the spec itself with Glob and Read. Plain Claude found all three defects without the plugin, so on this case myspec adds nothing. This is a description or triggering problem that no current check would catch.
2. **The default haiku judge gave a false negative.** It voted FAIL 3 times on a review that explicitly listed the empty and invalid range cases. Use `--judge-model sonnet` or a regex for long outputs.
3. In two-arm mode a case can score 1.0 while the skill never fired, so read the `withOnly` indicators separately.
4. **Hooks don't load in evals.** The run's init event shows `hooks: null`: the root `hooks.json` isn't on Claude's plugin-hook path, and myspec installs hooks per project through `init`. Hook behaviour still needs the bash suites, or an e2e harness that runs `init` first.
5. **CI needs:**
   - `ANTHROPIC_API_KEY`
   - `--trust-plugin`
   - `--scaffold --allow-tools Write Edit`
   - `--no-publish`
   - a pinned `--model` and `--judge-model`
   - `--max-cost-usd`

**Cost extrapolation** (pilot averages: about $0.10 and 30 s per plugin run, $0.05 per baseline run):

| Suite (30 short cases × 3 runs) | Cost | Time at `-j4` |
|---|---|---|
| Without ablation | ~$10 | ~12 min |
| With ablation | ~$15 | ~19 min |

Multi-step skills (feature-plan, feature-implement) will probably cost 3–10× more per run.

## 4. Eval seeds from myspec's own history

37 failure groups (about 55 of the 89 `fix` commits) were classified by which layer would have caught them:

| Kind | Rows | Best catch | Examples |
|---|---|---|---|
| Procedure-following | 7 | **LLM eval** | a3562ed feature-plan's gate exit pointed past the mode prompt; 837f68d plan coverage dropped REQ IDs that no AC restates; 9eb5d16 menus shown as bullets instead of AskUserQuestion |
| Subagent orchestration | 5 | **LLM eval** | 9ed2ed9 controller ran tasks itself and skipped the reviews; 31db66a/0d5c405 reviewer verdict format drifted; 75d610a subagent tried to ask the user |
| Artifact structure | 5 | static + LLM | 4f189a8 wrong frontmatter keys; fb20523 plan template had no frontmatter; 1ab9a1c tech-spec grew as an append-only log to 221 KB |
| Token bloat | 3 | LLM with a token budget + static | 21cf286 bootstrap read ~8k tokens to print "none"; ced9dba `load_when` loaded 3.2k tokens every session |
| Trigger / routing | 2 | static + LLM | 886a3ab descriptions summarised the workflow, so the body wasn't loaded; d60997b "Do NOT" sibling lines were removed |
| Hook bugs | 6 | deterministic | 8facc30 SIGPIPE above 64 KiB; 67f0814 root taken from cwd; 4334ff1 apostrophe inside a heredoc |
| Git/state edge cases | 3 (~10 commits) | deterministic | d9d9e59/19ec551 reviewer diff was empty or missed untracked files; a6cb428 "exits 0, empty" read as fresh |
| Stack-agnostic leak | 3 (~8 commits) | static + multi-language deterministic | 2e62824 File Inventory regex matched JS only |
| Other (doctor, packaging, init) | 3 | deterministic / static | c79f1c2 hook-wiring checker had false positives |

**Top 10 skills for behavioural evals** (number of fix commits in brackets):
1. feature-implement (17)
2. feature-plan (11)
3. feature-tech-spec-review (6)
4. feature-tech-spec (5)
5. update (9)
6. feature-complete (7)
7. bootstrap (8, runs every session)
8. init (5)
9. feature-spec / feature-spec-review (the pipeline's entry gate)
10. memorize / memorify / memory-create (the densest trigger collision)

**Fixtures already available:**
- `examples/skills/feature-plan.md` (3 scenarios), `examples/flows/full-feature-delivery.md`, `spec-drift-recovery.md`.
- The memorize/memorify/memory-sanitize examples contain scripted AskUserQuestion dialogues.
- The multi-language temp repos built inline in `backbone-audit.test.sh` and `spec-sync-dead-paths.test.sh` (Python, PHP, Go, Ruby) can become workspace generators.
- **Gap:** 17 skills have no example at all, including feature-spec-review, feature-tech-spec-review, doctor, init and update.

## 5. Concrete proposal: five layers

Each layer catches a different kind of failure. Put each check in the cheapest layer that can catch it.

### L0 — Static skill lint (deterministic, every PR, free)

A `scripts/lint-skills.mjs` in `test.yml`, modelled on BMAD but with the rules our own history produced:

| Rule | Source of the rule |
|---|---|
| description starts with "Use when", ≤1024 chars, no sequential workflow verbs | 886a3ab, AGENTS.md |
| description keeps its "Do NOT use for X (sibling)" line when a known sibling exists | d60997b |
| frontmatter keys come from an allowlist (`load_when`, `updated`, … rejected) | ced9dba, 4f189a8 |
| every "go to Step N" or "see §X" pointer resolves to a real heading | a3562ed |
| heading contracts: headings read by name (`mockup-design.md`, `code-review.md` `## Standards`, doctor anchors) exist on both sides | AGENTS.md, config contracts |
| no `dependencies: paths:` pointing into plugin-internal dirs | AGENTS.md v1.20.0 |
| SKILL.md token size ≤ budget; the delta per PR is printed | bloat rows |
| `bash -n` on all hooks | 4334ff1 |
| multi-stack grep (`prisma\|pnpm\|localhost:[0-9]`) as a warning with an allowlist | stack-leak rows |

skill-verify could become a scored LLM gate later (like Tessl's `--threshold 80`), but the deterministic subset should come first.

### L1 — Deterministic tests (extend what exists)

- Turn each D-row in §4 into a regression test in the existing bash suites; the hook and git/state rows are the most frequent.
- Add a **multi-language fixture generator** (`lib/tests/fixtures/make-repo.sh <stack>`) shared by the tests and by eval scaffolds.

### L2 — Behavioural evals with `claude plugin eval` (`evals/` at the repo root)

Five case families. Every case pairs a deterministic grader with an optional judge grader (superpowers' belt-and-braces rule).

| Family | Example cases | Graders |
|---|---|---|
| **Trigger matrix** | Per collision group: 2 should-trigger prompts per skill + 1 near-miss. E.g. "anything from this debugging worth keeping?" → memorify; "remember the staging DB rotates creds Mondays" → memorize; "why does the Stop hook keep blocking me?" → root-cause-debugging, not doctor | `tool_used Skill` (right one) + `max: 0` for each sibling, `--ablation none` |
| **Planted flaws** (review skills) | spec-review (untestable AC, contradiction, missing error state); tech-spec-review (a requirement not covered, reuse ignored); code-review (seeded bug in a PHP and a Python fixture); implement-review (REQ that was never implemented) | regex per planted flaw on `last_message` + recall; verdict consistent with findings; sonnet judge |
| **Artifact contract** | feature-spec → spec.md has the required sections and frontmatter; feature-plan from the golden tech-spec (837f68d's REQ-only IDs) → Spec Coverage lists every REQ, Execution Order table exists | `file_exists`, `regex` on `{source: file}` |
| **Procedure / orchestration** | feature-plan must stop at the mode prompt; feature-implement on a 2-task fixture plan dispatches Agent (not Edit first), and reviewer verdict lines match the format | `tool_order` (Agent before Edit), `tool_used Agent min: 2`, regex on the verdict format |
| **Cost / bloat** | bootstrap on a project with large indexes; trivial task through feature-implement | tracked `costUsd`, `turns`, doc bytes compared with the previous release (a measurement, not a hard gate) |

**Tiers:**
- **Every PR (touching `skills/`):** the trigger matrix and artifact-contract cases with free graders only: `--ablation none --runs 3 --threshold 0.8 --model sonnet --max-cost-usd 5`. Estimated ~$5 and ~10 min.
- **Before a release:** the full suite with two arms plus judges (`--judge-model sonnet`), then compared with the previous release (L3). Estimated $15–40.
- **Capability and regression evals are kept apart:** a new case starts as capability (it may fail) and moves to the regression tier once it passes reliably.

### L3 — Release comparison and trend

- `plugin eval`'s built-in Δ compares with no plugin at all. To answer "did this release regress?", run the same `evals/` against a worktree of the previous tag (copy `evals/` in) with `--ablation none`. Then compute **per-case paired differences**.
- **Decision rule:** ship when the paired-bootstrap 95% CI of the mean difference doesn't sit below 0 **and** pass^3 doesn't drop.
  - Worked example on 10 cases: mean +0.11, CI [0.03, 0.18].
  - A sign test is the cruder alternative.
- Append one line per release to `quality/trend.jsonl`. `/release` reads it and prints the change since the last release:
  ```json
  {"version":"2.8.0","date":"2026-10-06","model":"sonnet","cases":30,"pass_rate":0.91,"pass3":0.83,
   "mean_delta_vs_none":0.41,"paired_delta_vs_prev":{"mean":0.03,"ci":[-0.02,0.07]},
   "cost_usd":14.2,"median_turns":9,"flaky":["review-planted-flaws"]}
  ```
- **Predictability metrics** from n trials with c passes:
  - pass@k = 1 − C(n−c,k)/C(n,k)
  - pass^k = C(c,k)/C(n,k)
  - Example: n=5, c=3 gives pass@3 = 1.0 but pass^3 = 0.10.
  - For generated docs, also track heading-set Jaccard across runs, the coefficient of variation of the requirement count, and the share of runs with every required section.

### L4 — Field signal (local only, opt-in)

- **friction-scan `--emit`**, run from a `SessionEnd` hook, appends one record per skill run to the gitignored `.claude/state/metrics/runs.jsonl`:
  ```json
  {"schema":1,"kind":"skill","myspec":"2.7.0","skill":"myspec:feature-implement","trigger":"user-slash",
   "feature":"billing-export","active_ms":1843000,"turns":14,"subagents":6,
   "tokens":{"in":48210,"out":61877,"cache_read":2104332},"hook_blocks":{"reuse-audit":1},
   "fix_rounds":2,"subagent_status":{"DONE":5,"BLOCKED":1},
   "outcome":{"status_before":"planned","status_after":"implemented"}}
  ```
  - Token counts come from `message.usage` on assistant transcript entries; deduplicate by `message.id`.
  - A skill window runs from its `Skill` tool_use to the next skill call or user prompt.
  - No content is stored, only counts, names and timestamps.
- **`doctor` or a new `myspec stats`** summarises that file: slowest and most expensive skills, BLOCKED rate, fix rounds per feature, and hook block rate by hook. Every red flag is a candidate eval case.
- **OpenTelemetry (document it, don't ship it).** Claude Code ignores OTEL env vars in a repo's `.claude/settings.json`, so users opt in themselves. Setup:
  - Set `CLAUDE_CODE_ENABLE_TELEMETRY=1` and `OTEL_LOG_TOOL_DETAILS=1` (without it, myspec skills show as `custom_skill`). Per-skill cost attributes need ≥ 2.1.273.
  - Use an otelcol file exporter.
  - Useful events: `skill_activated` (`invocation_trigger` = user-slash / claude-proactive / nested-skill); `hook_execution_complete.num_blocking`; `subagent_completed.total_tokens`.
  - The **proactive activation rate per skill** is the field measure of triggering.
- **`/skill-doctor`** already shows 7-day cost, tokens and uses per skill, and flags skills that were never invoked.
- **Consent model:** OpenSpec, Homebrew and Next.js all use opt-out upload with an env kill switch. For myspec, keep everything local and honour `DO_NOT_TRACK`. Uploading happens only through an explicit export or `/feedback`-style command.

### L5 — Outcome metrics in downstream projects (from git + index.yaml + docs)

| Metric | Formula |
|---|---|
| Spec→merge lead time | merge time of the PR touching the feature − first commit of spec.md (median, P85) |
| Stage dwell | gaps between `index.yaml` status transitions (`git log -p`) |
| Plan deferral rate | deferred / (checked + deferred) tasks |
| Conformance first-time pass | PASS with no earlier FAIL / all features |
| **Feature rework rate** (DORA 2025 analogue) | `fix:` commits touching the feature's inventory paths ≤30 days after `complete` / all commits touching those paths |
| Spec churn | `spec_version` bumps after `implemented` |

The METR RCT found developers were 19% slower with AI tools while believing they were 20% faster, so outcome metrics have to come from artifacts, not self-report.

## 6. Suggested sequencing

1. **Week 1: L0 lint + trend file.** Deterministic, free, and catches about a third of the historical fix classes. Also fix the pilot's feature-spec-review triggering finding.
2. **Week 1–2: L2 seed suite of about 15 cases.**
   - The trigger matrix for 3 collision groups: memory capture, review family, audit family.
   - 3 planted-flaw cases.
   - 2 artifact-contract cases (feature-spec, feature-plan).
   - Run on PRs with free graders only.
3. **Week 2–3: L3 release comparison.** Wire it into `/release` preflight as a report first, and make it a gate only after a few releases of baseline data.
4. **Week 3+: L4 friction-scan `--emit` + stats.** Then grow L2 toward 30–50 cases, adding one case for every user-reported failure.

## 7. Open questions for the brainstorm

- Which model or models to pin for evals: sonnet only, or also haiku, since downstream users run cheaper models?
- Budget: is ~$5 per skill-touching PR and $15–40 per release acceptable? Who pays for CI (an API key in repo secrets)?
- Should PR evals block, or only report, until there is baseline data?
- How far to go on the orchestration-heavy skills (feature-implement), where one run may cost $1+? One nightly case, or skip them in CI entirely?
- Hooks are out of `plugin eval`'s reach. Is an e2e harness (`claude -p` in a scaffolded, `init`-ed repo) worth building, or do the bash suites suffice?
- Should L4 field metrics feed the eval backlog automatically (friction-scan flags → a candidate case), or stay manual?
- Should evals become a shipped feature? `skill-verify` already recommends `plugin eval` downstream; myspec could add a skill that writes evals for a project's own skills.

## Sources

**Claude Code**
- https://code.claude.com/docs/en/plugin-evals
- https://code.claude.com/docs/en/monitoring-usage
- https://code.claude.com/docs/en/headless

**Anthropic**
- https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents
- https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices
- https://github.com/anthropics/skills/tree/main/skills/skill-creator (SKILL.md, agents/grader.md, agents/analyzer.md, references/schemas.md)
- https://www.anthropic.com/research/statistical-approach-to-model-evals

**superpowers**
- https://github.com/prime-radiant-inc/superpowers-evals (docs/scenario-authoring.md, scenarios/*)
- https://github.com/obra/superpowers/blob/main/docs/testing.md
- https://github.com/obra/superpowers/blob/main/skills/writing-skills/testing-skills-with-subagents.md

**Tessl**
- https://docs.tessl.io/llms-full.txt
- https://tessl.io/blog/three-context-eval-methodologies/

**Other frameworks and tools**
- https://github.com/bmad-code-org/BMAD-METHOD/blob/main/tools/validate_skills.py
- https://www.promptfoo.dev/docs/guides/test-agent-skills/
- https://github.com/github/spec-kit/tree/main/tests
- https://github.com/Fission-AI/OpenSpec/blob/main/openspec/specs/telemetry/spec.md

**Papers and metrics**
- https://arxiv.org/abs/2406.12045 (pass^k)
- https://arxiv.org/abs/2107.03374 (pass@k)
- https://arxiv.org/abs/2606.30689
- https://arxiv.org/abs/2604.05278

**Industry writing**
- https://martinfowler.com/articles/exploring-gen-ai/sdd-3-tools.html
- https://uvik.net/spec-driven-development-benchmark/
- https://dora.dev/guides/dora-metrics/
- https://getdx.com/blog/ai-measurement-framework-guide/
- https://metr.org/blog/2025-07-10-early-2025-ai-experienced-os-dev-study/

**Verification status:**
- Checked by hand: the `plugin eval` CLI and the pilot numbers in `aggregate-result.json`.
- Checked at source by the research agents: the repo excerpts (repos cloned) and the OTel attributes (docs fetched).
- Not re-verified: the study figures, which come from abstracts or vendor posts.
