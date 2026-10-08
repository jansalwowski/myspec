# Evaluating LLM agents, skills, and prompts: external research

Researched 2026-10-07. Every claim has a URL. **[unverified]** marks a claim I could not confirm against a primary source. **[computed]** marks arithmetic I did myself from cited formulas, not a claim taken from a source.

---

## 0. TL;DR for this suite

- 25 cases cannot detect small regressions, whatever statistics you run on them. With 25 paired cases, the minimum detectable mean difference is about 11-22 points (§2.3). Spend the budget where noise matters: more cases, not more model × trial combinations on cases that always pass.
- Most cost goes into full agent runs that keep going after the graded event has already happened. Trigger and routing cases need a single-turn check that stops early. Anthropic's own skill-creator already works this way: it kills `claude -p` at the first tool call (§4.2).
- `claude plugin eval` runs a no-plugin baseline arm by default, which doubles cost. `--ablation none` halves it when you only compare against the previous release (§3.1).
- The tool documents no result cache and no "stop once the grader is satisfied" option. Content-hash caching and change-impact selection have to live in a wrapper (§3.5, §3.6).

---

## 1. Fundamentals

### 1.1 Vocabulary (Anthropic, "Demystifying evals for AI agents", Jan 2026)
Source: https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents

- **Eval**: "give an AI an input, then apply grading logic to its output to measure success."
- **Task** (also called a problem or test case): one test with defined inputs and success criteria.
- **Trial**: one attempt at a task. Outputs vary between runs, so you run several trials.
- **Grader**: logic that scores one aspect of performance. A task can have several graders, and each grader can have several assertions.
- **Transcript** (also called a trace or trajectory): the complete record of a trial, including tool calls, reasoning, and intermediate results.
- **Outcome**: the final state of the environment. In the article's flight-booking example, the outcome is whether a reservation exists in the database, not what the agent said.
- **Evaluation harness**: the code that runs tasks, records results, and aggregates them. The **agent harness** (scaffold) is the code that makes the model an agent. "Evaluating an agent" means evaluating the harness and the model together.
- **Suite**: a collection of tasks.

### 1.2 Capability vs regression evals
Same source.

- **Capability evals** ask what the agent can do. They should *start at a low pass rate* and give the team "a hill to climb."
- **Regression evals** ask whether the agent still does what it used to. They should sit *near 100%*.
- Saturated capability tasks "graduate" into the regression suite.

**Implication for this suite.** Regression and capability cases need different statistics. A regression case answers "did this break?", so a cheap, high-power detector of flips is what matters. A capability case answers "how good is it?", so a pass rate with a CI is what matters. Mixing them in one aggregate CI blurs both.

### 1.3 pass@k vs pass^k

- **pass@k** is the probability that at least one of k trials succeeds. **pass^k** is the probability that all k succeed. Example: at 75% per-trial success, pass^3 = 0.75³ ≈ 42%. As k grows, pass@k approaches 1 and pass^k approaches 0. https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents
- pass^k was introduced by τ-bench. Its unbiased estimator, with n trials and c successes per task, is `pass^k = E_task[C(c,k)/C(n,k)]`, and the companion is `pass@k = 1 − E_task[C(n−c,k)/C(n,k)]`. τ-bench found gpt-4o at pass^8 < 25% in retail. https://arxiv.org/abs/2406.12045 (formula confirmed in https://arxiv.org/html/2406.12045)
- **[computed]** With exactly n = k = 3 runs, pass^3 is simply "all 3 passed." That number is very noisy per case. A case with a true 90% per-trial pass rate shows at least one failure in 3 runs 27% of the time. At 80% the figure is 49%. A pass^3 "regression" on one case is therefore usually noise unless the case is near 100% reliable.

### 1.4 Grader types
Source: https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents

| Type | Strengths | Weaknesses |
|---|---|---|
| Code (string/regex match, tool-call verification, outcome checks) | Fast, cheap, objective, reproducible | Brittle to valid variation; little nuance |
| Model (rubric, NL assertions, pairwise) | Flexible, handles open-ended output | Non-deterministic, costs more, needs calibration against humans |
| Human | Gold standard | Slow, expensive |

Practices for judges:
- Calibrate the judge against human experts. Give it an "Unknown" escape hatch. Grade each rubric dimension with a separate judge (same source).
- Use one judge per failure mode, and give it only the slice of the trace it needs. Measure the judge's TPR and TNR against a held-out human-labelled set. Label 100-200 examples per failure mode for judge development. https://hamel.dev/blog/posts/evals-faq/
- Prefer pass/fail or pairwise verdicts over open-ended scores. Control for length bias, and ask for reasoning before the verdict. https://developers.openai.com/api/docs/guides/evaluation-best-practices
- In `claude plugin eval`, an `llm` grader passes on 2 of 3 judge votes. Its verdict varies more the longer the text it reads. The docs recommend `regex` over long files and keeping `llm` graders for short outputs. If `tool_used: Skill` passes but Δ is negative, "suspect the judge before the plugin." https://code.claude.com/docs/en/plugin-evals.md

### 1.5 Grade outcomes, not paths (mostly)

- "It's often better to grade what the agent produced, not the path it took." Rigid checks on exact tool sequences make tests "overly brittle." Transcript metrics such as turns, tool usage, and tokens are still useful as constraints. https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents
- The plugin-eval docs recommend one grader on the result (final message or file) plus one on the steps (`tool_used` or `tool_order`). Together they show both that the answer was right and that the plugin produced it. https://code.claude.com/docs/en/plugin-evals.md
- For multi-step agents, Hamel recommends two phases. First check end-to-end success. Then do step-level diagnosis using a **transition failure matrix**: rows are the last successful state, columns the first failure. Fix process failures first, because they are more deterministic. https://hamel.dev/blog/posts/evals-faq/

**Implication.** Your `tool_order` graders on orchestration cases are path checks. Keep them only where the order itself is the contract, such as "dispatch the subagent before writing the artifact."

### 1.6 Process advice from practitioners

- Start with 20-50 tasks drawn from real failures. Early changes have large effects, so small samples suffice at first. https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents
- Error analysis comes first: "Error analysis is the most important activity in evals." Write evaluators "for errors you discover, not errors you imagine." "If you're passing 100% of your evals, you're likely not challenging your system enough." https://hamel.dev/blog/posts/evals-faq/
- Evals are a process, essentially the scientific method. Balance the labelled data at roughly 50:50 pass/fail, and calibrate automated evaluators against human labels. https://eugeneyan.com/writing/eval-process/
- A good task is one where two domain experts independently reach the same verdict. Include a reference solution that passes all graders. If a frontier model scores 0% across many trials, suspect the task or grader before the agent. https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents
- Keep trials isolated. Shared state inflates scores: one internal example had Claude reading git history left by earlier trials. Same source.

---

## 2. Statistics

### 2.1 "Adding Error Bars to Evals" (Evan Miller, Anthropic, Nov 2024)
Sources: https://www.anthropic.com/research/statistical-approach-to-model-evals and https://arxiv.org/abs/2411.00640 (formulas from https://arxiv.org/html/2411.00640)

- **Report the SEM.** The 95% CI is mean ± 1.96·SEM, and for binary scores SE = √(p̄(1−p̄)/n).
- **Cluster the standard errors** on the unit of randomization when items share a source. Clustered SEs on popular evals "can be over three times as large as naive standard errors" (DROP: 1.34 vs 0.44). *Relevance here*: the 3 runs of one case are a cluster, not 3 independent observations. So are cases that share a fixture or a skill. Treating 75 runs as n = 75 overstates precision. Bootstrap by case, not by run.
- **Resample K times per question and average.** This removes within-question variance. In their uniform-difficulty example, Var(μ̂ | K) = Var(μ̂ | K=1) × (1 + 2/K)/3. K = 2 cuts variance by 1/3, K = 4 by 1/2, and the ceiling is 2/3. Pick K so that E[σ²]/K ≪ Var(x). Past that point, extra resamples barely help. *So extra trials have sharply diminishing returns. Extra cases do not.*
- **Paired differences.** When both models answer the same questions, `Var_paired = Var_unpaired − 2·Cov(x_A, x_B)/n`. Frontier models' per-question scores correlate at 0.3-0.7 on popular evals, so pairing cuts the variance a lot. Report the mean difference, SE, CI, and correlation.
- **Sample size (Eq. 9):** `n = (z_{α/2}+z_β)² (ω² + σ_A²/K_A + σ_B²/K_B) / δ²`. Worked example: δ = 3 points at α = 0.05 and power 0.8 needs about **969 questions**. The paper suggests new evals have at least about 1,000. In a second example, with n = 198 and correlation 0.5, raising K from 1 to 10 shrinks the minimum detectable effect from **13.2% to 7.5%**.

### 2.2 Other noise sources

- **Infrastructure noise** (Anthropic, Feb 2026). On Terminal-Bench 2.0, resource configuration alone moved scores by 6 points (p < 0.01), more than the gaps between top models. Pass rates "fluctuate with time of day, likely because API latency varies," which they have "not formally quantified." They recommend running "at multiple times and on multiple days" to average out the noise. https://www.anthropic.com/engineering/infrastructure-noise
- **Rate limits look like regressions.** In `claude plugin eval`, once you hit a usage or rate limit, every later run errors and usually scores 0, and the suite is *not* marked partial. Check `cases[].arms.with[].error` before believing a drop. https://code.claude.com/docs/en/plugin-evals.md
- **Seed variance.** Madaan et al. measure benchmark variance and argue comparisons must factor it in. Classical item-analysis and IRT methods "struggle to meaningfully reduce variance." https://arxiv.org/abs/2406.10229
- **Signal-to-noise.** Heineman et al. (AI2, 2025) define signal (how well a benchmark separates models) and noise. Removing noisy subtasks from multi-task suites raises the aggregate SNR. https://arxiv.org/abs/2508.13144 *Relevance*: drop or quarantine your noisiest cases from the release gate instead of averaging them in.

### 2.3 What 25 cases can and cannot detect [computed]

The formula below is Eq. 9 rearranged, with K folded into the per-case SD of differences.

- Minimum detectable effect (MDE) = 2.8 · SD_diff / √n_cases at α = 0.05 and power 0.8.
  - With 25 cases and a per-case diff SD of 0.2 / 0.3 / 0.4, the MDE is **11 / 17 / 22 points**.
  - With 50 cases it is 8 / 12 / 16. With 100 cases it is 6 / 8 / 11.
- **Sign test / exact McNemar.** Only discordant cases (those that changed) carry information. The exact test is a Binomial(b + c, 0.5) test. https://www.medcalc.org/en/book/mcnemar-test.php and https://metricgate.com/docs/mcnemar-exact-test/
  - Even if every flip goes the same direction, 5 flips give a two-sided p of 0.0625. You need 6 or more flips, all in the same direction, to reach p < 0.05.
  - So on a 25-case suite where releases typically flip 0-3 cases, **the sign test can almost never fire**. It is not wrong. It just has no power here.
- **Paired bootstrap at small n.** Percentile bootstrap CIs tend to undercover below about n = 20-30. In one simulation only bootstrap-t reached nominal coverage, and only at n ≥ 20. https://www.ispor.org/heor-resources/presentations-database/presentation-cti/ispor-europe-2025/poster-session-2-2/bootstrap-methods-for-confidence-interval-estimation-in-small-samples-implications-for-health-economics (poster; secondary) **[unverified primary]**. A 25-case bootstrap CI is likely somewhat *too narrow*, not too wide.
- **Wilson 95% intervals** for single cases: 3/3 → [0.44, 1.0], 9/10 → [0.60, 0.98], 25/25 → [0.87, 1.0]. Three runs tell you almost nothing about one case's true rate.

**Practical reading.**
- At this suite size, treat the statistics as a *screen for large breaks*.
- Treat per-case flips as *triage prompts to read transcripts*.
- Use run-to-run reproducibility (re-run only the flipped cases) to confirm.

This matches Anthropic's advice to read transcripts rather than take scores at face value.

### 2.4 Sequential testing and early stopping

- **Optional stopping invalidates fixed-n CIs.** If you stop because results "look good enough," classical intervals lose validity. *Anytime-valid confidence sequences*, built on test supermartingales, keep coverage at any stopping time. (Hsu & Shekhar, Michigan, from search-result overviews.) https://arxiv.org/pdf/2607.17409 **[unverified: I read the overview, not the paper]**
- **Bayesian optimal stopping ("optstop")** (UK AISI, Aug 2026) treats an eval as sequential measurement. It keeps sampling the items that are still uncertain and stops the precise ones. In a 200-item × 10-epoch eval it removed **57-97% of planned trials** across nine settings, with conclusions equivalent to the full run. It samples more cautiously near 0% performance. Savings depend on design. https://www.aisi.gov.uk/research/knowing-when-to-stop-bayesian-optimal-stopping-for-llm-evaluations (paper: https://arxiv.org/pdf/2608.14425)
- **SPRT-style rules** (e.g., CONSOL) are for stopping self-consistency sampling once the majority answer is statistically settled. https://alphaxiv.org/overview/2503.17587v1 **[unverified: overview only]**

**Translation to this suite: an adaptive trial-count policy.** Run every case once. Only cases that fail, or whose single result disagrees with the previous release, get runs 2 and 3, and up to 5 if still split. Because a Bayesian posterior per case stays valid under data-dependent stopping, gate on the posterior P(p_case < threshold) rather than a fixed-n CI. This is the optstop idea in miniature. It is *my design suggestion*, not a published recipe for plugin evals.

---

## 3. Cost and time reduction

### 3.1 Levers already built into `claude plugin eval`
Source for all items: https://code.claude.com/docs/en/plugin-evals.md

- **Cost model**: roughly cases × runs agent runs with the plugin, the same number again for the no-plugin baseline, plus 3 judge calls per `llm` or `baseline` grader per run.
- **`--ablation none`** runs one arm, which "halves the cost when you don't need the comparison."
  - *Big lever*: release-vs-release comparisons don't need the no-plugin arm on every release.
  - Caveat: in two-arm mode `tool_used: Skill` graders are excluded from scoring (`scored: false`), but under `--ablation none` nothing is excluded. Absolute scores therefore differ between modes. Don't compare a two-arm baseline against a one-arm run.
- **Graders**: `regex`, `tool_used`, `tool_order`, and `file_exists` "cost nothing." `llm` and `baseline` call a judge. There are no custom-code graders. For "quick every-change suites," the docs say to use only non-judge graders plus `--ablation none`.
- **`--runs <n>`** (default 3, range 1-50; per-case `runs` in frontmatter). "A single run is noisy, so confirm any change at the default three runs before you trust it."
- **`--case <glob>` / `--tag <tag>`** select subsets. This is your hook for change-impact selection (§3.6).
- **`-j/--concurrency`** goes from 1 (default) to 8. Runs "share your account's rate limit, so this shortens wall-clock time rather than raising throughput past that limit."
  - *If you are running at `-j 1`, this is likely the largest wall-clock win available.*
- **`max_turns`** defaults to 10 (max 200) and **`timeout_seconds`** to 300. Hitting either counts as a run error. The docs advise setting them generously and using `--max-cost-usd` as the ceiling instead. So tight turn caps are *not* the docs' recommended cost lever, because they cause false failures.
- **`--max-cost-usd`** is checked before each run starts and exits 2 with `partial: true`. Leave partial and `skippedPaidGraders` runs out of trend charts.
- **`--model` / `--judge-model`**: pin both in CI. A cheap default judge can misjudge formatting.
- **Mocks**: MCP tools answer from mock files. `type: agent` mocks call the judge model, but their answers can be adopted into `mocks/.replay/`, after which "later runs answer the identical call from it with no model call." This is the only built-in response cache.
- **`expect:` / `abort_when`** on mocks can abort a run, which then scores 0. That is a failure-path early stop, not a success-path one.
- **Not documented**: any cross-run result cache, or "stop the run once a grader is already satisfied." Treat both as absent unless `claude plugin eval --help` shows otherwise. **[unverified: I did not run --help]**

### 3.2 Cheaper models where valid

Pricing per MTok, input/output (https://platform.claude.com/docs/en/about-claude/pricing):

| Model | Input | Output |
|---|---|---|
| Sonnet 5 / 5.5 | $2 | $10 |
| Haiku 4.5 | $1 | $5 |
| **Haiku 5.5** (prompts ≤ 100k) | **$0.10** | **$0.50** |

- If your "Haiku" arm is Haiku 4.5, moving it to Haiku 5.5 is a large price drop.
  - Caveat: behaviour differs by model, and Anthropic's skill-authoring guide says to test the models you actually ship for. https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices
- **Validity rule**: use a cheaper model only for cases where *model capability isn't the variable under test*. Deterministic artifact-contract checks are an example. Routing behaviour, by contrast, can differ between models.
- Skill-creator's trigger optimizer explicitly uses "the model ID from the system prompt, so the test matches the user's actual experience." https://raw.githubusercontent.com/anthropics/skills/main/skills/skill-creator/SKILL.md
- **Judges**: Hamel says a smaller judge can suffice if it still catches errors (validate its TPR/TNR). https://hamel.dev/blog/posts/evals-faq/ The plugin-eval docs warn that small judges misjudge formatting. https://code.claude.com/docs/en/plugin-evals.md

### 3.3 Prompt caching

Source: https://platform.claude.com/docs/en/build-with-claude/prompt-caching

- **Pricing**: cache reads cost 0.1× base input, 5-minute writes 1.25×, 1-hour writes 2×. The default TTL is 5 minutes, refreshed on each hit.
- **Minimum cacheable prefix**: 512 tokens on Haiku 5.5 / Sonnet 5.5 / Opus 5.5; 1,024 on Sonnet 5; 4,096 on Haiku 4.5.
- **Invalidation**: the order is tools → system → messages. Changing tool definitions invalidates everything.
- **Concurrency**: "A cache entry only becomes available after the first response begins. If you need cache hits for parallel requests, wait for the first response before sending subsequent requests."
  - *Implication* **[inference]**: firing all `-j 8` runs at the same instant may make every run pay a cache write. Staggering the first run of each model may help. Measure it.
- **Claude Code** manages caching automatically unless `DISABLE_PROMPT_CACHING` is set. https://code.claude.com/docs/en/prompt-caching.md (localized copies seen via search; https://github.com/anthropics/claude-code/issues/48090)
  - Make sure CI doesn't set that variable.
  - Your plugin's ~45 skill descriptions are part of the system prefix. They are cached across turns within a run, and probably across runs within 5 minutes if the prefix is byte-identical. **[unverified: cross-session cache reuse in headless runs]**

### 3.4 Batch API: not applicable to agent CLI runs

- The Batch API gives 50% off, and most batches finish within 1 hour (up to 24 hours). Each request is processed *independently*. https://platform.claude.com/docs/en/build-with-claude/batch-processing
- An agent loop needs a model call → tool result → model call round trip. Each turn would be a separate batch with up to an hour of latency, and `claude plugin eval` / `claude -p` talk to the regular API.
- Anthropic's own Managed Agents pricing says batch "doesn't apply" because "sessions are stateful and interactive." https://platform.claude.com/docs/en/about-claude/pricing
- **Where Batch *does* fit**: a single-turn routing classifier (§4.3), or offline LLM-judge regrading of saved transcripts. Both are single Messages calls. Batch and cache discounts stack (same pricing page).

### 3.5 Content-hash result caching

- No built-in cache exists in `claude plugin eval` (§3.1). The pattern exists elsewhere.
  - promptfoo caches by provider ID + request digest + provider config + context vars, with a 14-day TTL.
  - Each `--repeat` index gets its own cache namespace, so repeated trials stay distinct.
  - Errors and empty responses are not cached.
  - https://www.promptfoo.dev/docs/configuration/caching/
- **Applied here** (design suggestion):
  - Key each case result on hash(case dir, the SKILL.md files and agents it can reach, plugin manifest, model ID, Claude Code version, run index).
  - On a release where none of those changed, reuse the last result instead of re-running.
- **Caveats**:
  - Model-side drift under a pinned model ID is not captured.
  - The skill *listing* includes every skill's description, so editing any description can change routing for every trigger case. Hash all descriptions for routing cases, and only the reachable skill bodies for execution cases.
  - **Caching a stochastic result just freezes one sample.** It is fine for "nothing changed," but not as evidence of reliability.

### 3.6 Test selection by change impact

- Use `--case` / `--tag` to run only the cases whose hashed inputs changed, plus a small always-run smoke set. https://code.claude.com/docs/en/plugin-evals.md
- Hamel describes CI sets as small and purpose-built (core features, past-bug regressions, known edge cases). Weigh each test's cost against how often it runs, and phase out expensive evals more aggressively than cheap ones. https://hamel.dev/blog/posts/evals-faq/
- **Map**: case → skills it touches, plus the global description listing for trigger cases.

### 3.7 Adaptive trials and stratified sampling

- See §2.4: optstop removed 57-97% of trials with equivalent conclusions. https://www.aisi.gov.uk/research/knowing-when-to-stop-bayesian-optimal-stopping-for-llm-evaluations
- From Miller, extra trials past the point where within-case variance is small add almost nothing (§2.1). Cases at 100% across recent releases are the cheapest place to cut to 1 run.
- **tinyBenchmarks**: about 100 curated examples can reproduce MMLU-scale (14K) estimates. That suggests a smaller, *curated* representative subset can stand in for a full run. https://arxiv.org/abs/2402.14992 (method details not verified from the abstract)
- **Stratify by case type** (trigger / review / artifact / orchestration) so that a cheap subset still covers each behaviour family.

### 3.8 Reduce fixture and context size

- The skill listing costs context on every turn. Its budget scales at 1% of the model's context window, and when it overflows Claude Code drops descriptions "starting with the skills you invoke least." Each description plus `when_to_use` is capped at 1,536 characters. https://code.claude.com/docs/en/skills
  - Smaller descriptions are cheaper on every eval turn and change routing behaviour.
  - Whether a fresh eval sandbox has invocation history that affects which descriptions get dropped: **[unverified]**.
- Each run starts in an empty directory, and `scaffold_script` builds the fixtures (`--scaffold`, 120 s limit). Small fixtures mean fewer Read and Grep tokens. https://code.claude.com/docs/en/plugin-evals.md
- Resume from a recorded transcript with `context.history_file` to skip expensive setup turns. The case prompt becomes the next user turn. Such cases run one arm by default when the target is a path. https://code.claude.com/docs/en/plugin-evals.md
  - *This is a strong lever for multi-step orchestration cases*: record the expensive early phase once, then evaluate only the decision turn you care about.

### 3.9 Parallelism and rate limits

- `-j` up to 8. Runs share the account rate limit (§3.1).
- Rate-limit errors score 0 without marking the run partial (§2.2). Higher concurrency can therefore *manufacture* regressions. Gate on `error == null`.

---

## 4. Trigger and activation testing for skills

### 4.1 What triggering depends on

- The `description` (plus `when_to_use`) is what Claude matches against. Put "the key use case first." https://code.claude.com/docs/en/skills
- "Claude consults skills only for tasks it can't easily handle alone." Simple one-step queries may not trigger a skill even when the description matches, so trigger prompts must be substantive. https://raw.githubusercontent.com/anthropics/skills/main/skills/skill-creator/SKILL.md
- Descriptions must be third person and say both what and when (max 1,024 characters in the API skills spec). https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices
- Test both directions. "One-sided evals create one-sided optimization": balance under- against over-triggering. https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents

### 4.2 Anthropic's cheap trigger harness (skill-creator `run_eval.py`)
Source: https://raw.githubusercontent.com/anthropics/skills/main/skills/skill-creator/scripts/run_eval.py

- **Invocation**: `claude -p <query> --output-format stream-json --verbose --include-partial-messages [--model M]`.
- **Install**: the skill under test is written as a uniquely named temporary command file in `.claude/commands/` and deleted afterwards.
- **Early termination**: the script reads the stream line by line.
  - On the first `tool_use` that is not `Skill` or `Read`, it returns **False immediately**.
  - If it is `Skill` or `Read`, it accumulates `input_json_delta` and returns **True as soon as the unique name appears**.
  - The process is then killed.
  - *A trigger trial costs one partial model turn, not a full agent run.*
- **Defaults**: 30 s timeout, `--num-workers 10`, `--runs-per-query 3`, `--trigger-threshold 0.5`. A should-trigger query passes if its rate is ≥ 0.5, and a should-not query passes if its rate is < 0.5.
- **Eval set** (SKILL.md): 20 queries, 8-10 should-trigger and 8-10 should-not. The best negatives are "near-misses" that share keywords but need something else. Easy negatives "don't test anything." Use a 60/40 train/test split. Pick the best description by **held-out** test score "to avoid overfitting." https://raw.githubusercontent.com/anthropics/skills/main/skills/skill-creator/SKILL.md
- **Caveat**: it tests one skill in isolation as a command file, not the full 45-skill listing with its siblings, so sibling confusion is under-tested.
- **Caveat**: a GitHub issue reported that `claude -p` never triggered skills in this loop (0% recall). It is marked resolved. Confirm on your Claude Code version. https://claudeissues.com/issue/36570-claude-p-does-not-trigger-skills-skill-creator-eval-loop-always-shows-0-recall **[unverified fix]**

### 4.3 Even cheaper: a description-only routing classifier

- **Pattern** (community): give a model every skill's name and description plus the user prompt, and ask which skill (or none) should fire. Never run the agent. https://skills.sh/Dataslayer-AI/Marketing-skills/ds-eval (third-party; seen via search) **[unverified details]**
- **Pros**:
  - One short call per prompt. Prompt caching covers the shared 45-description prefix, and the Batch API fits.
  - It directly tests sibling disambiguation across the whole listing.
- **Con**: it is a *proxy*. It doesn't use Claude Code's real system prompt, listing truncation, or the "can I handle this myself?" behaviour (§4.1). Use it for fast iteration on descriptions and as a per-push gate, then confirm periodically with real stream-and-kill runs (§4.2) or `tool_used: Skill` cases.
- **Suggested shape**: 20-40 labelled phrases with about 25% negatives. https://pasqualepillitteri.it/en/news/341/claude-code-skills-2-0-evals-benchmarks-guide (third-party) **[unverified]**

### 4.4 In `claude plugin eval` specifically
Source: https://code.claude.com/docs/en/plugin-evals.md

- Use `tool_used` with `tool: Skill` and `input_match: '"skill"\s*:\s*"(?:[\w-]+:)?your-skill-name"'`.
- For "sibling must not fire," use `min: 0, max: 0` with **`arm: both`**. Otherwise Skill graders are unscored in two-arm runs.
- The docs say the most common first finding is Δ ≈ 0 with the `tool_used: Skill` grader failing, which means the description doesn't trigger on natural phrasing.
- **Cost note**: a trigger case here runs the full agent until it finishes or hits `max_turns`, even though the verdict was decided at the first tool call. That is the main waste relative to §4.2. Mitigations:
  - (a) Keep trigger cases' prompts self-contained and `allowed_tools` minimal (e.g. `[Skill]` only), so the run ends quickly after the skill loads. **[inference; measure turns]**
  - (b) Move bulk trigger coverage to a §4.2 / §4.3 harness, and keep only a few `tool_used: Skill` smoke cases in the expensive suite.

---

## 5. Anti-patterns and pitfalls

1. **Graders that can't fail, or always fail.** Remove assertions that pass in both arms, and investigate those that fail in both. https://agentskills.io/skill-creation/evaluating-skills Skill-creator's analyst flags "non-discriminating assertions (those that always pass)." https://raw.githubusercontent.com/anthropics/skills/main/skills/skill-creator/SKILL.md
   - *Test*: run the grader against a deliberately broken output. Anthropic recommends a reference solution that passes every grader. https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents
   - For planted-flaw review cases, also run a "clean" twin with no flaw. A grader that passes on the clean twin can't fail.
2. **Grader bugs masquerading as capability limits.** Opus 4.5 scored 42% on CORE-Bench because the grader rejected "96.12" against "96.124991…". After the grading was fixed (and the scaffold loosened) it scored 95%. https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents
3. **Ungraded spec requirements.** Everything a grader checks must be stated in the task, such as file paths (same source).
4. **Regex on the wrong target.** The default `target` is `last_message`, not the trace. Trace JSON escapes quotes as `\"`. `files` means the list of paths, not file contents. https://code.claude.com/docs/en/plugin-evals.md
5. **Saturation.** "An eval at 100% tracks regressions but provides no signal for improvement." Revise saturated capability evals or move them to the regression set. https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents
6. **Flaky cases.**
   - High run-to-run SD means either the eval is flaky or the skill is ambiguous. Tighten the instructions or add examples. https://agentskills.io/skill-creation/evaluating-skills
   - Shared state between trials causes correlated failures. https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents
   - Removing noisy items raises SNR. https://arxiv.org/abs/2508.13144
   - *Practice*: track per-case flip rates across releases, and quarantine high-flip cases from the gate until fixed.
7. **Overfitting to the eval.**
   - Pick description variants on a held-out split. https://raw.githubusercontent.com/anthropics/skills/main/skills/skill-creator/SKILL.md
   - "Generalize from feedback" rather than narrow patches. https://agentskills.io/skill-creation/evaluating-skills
   - Writing evals for imagined errors wastes effort. https://hamel.dev/blog/posts/evals-faq/
8. **Rigid path checks.** Exact tool sequences are brittle. https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents
9. **Misreading the CI gate.**
   - `--threshold` reads the *with-arm* score, never Δ. Δ "never changes the exit code."
   - Rate-limited runs score 0 without being marked partial.
   - Two-arm and one-arm absolute scores differ.
   - https://code.claude.com/docs/en/plugin-evals.md
10. **Unvalidated judges.** Measure TPR and TNR against human labels. https://hamel.dev/blog/posts/evals-faq/ Calibrate against humans. https://developers.openai.com/api/docs/guides/evaluation-best-practices
11. **Taking scores at face value.** "Read the transcripts!" https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents
12. **False precision from runs-as-samples.** Cluster by case (§2.1). Treat a small-n percentile bootstrap as optimistic (§2.3).

---

## 6. Things I could not verify

- Whether `claude plugin eval --help` exposes caching or success-path early-stop flags beyond the documented ones. I did not run it.
- Whether prompt-cache hits carry across separate headless `claude` sessions in an eval run.
- How the skill-listing truncation chooses which descriptions to drop in a fresh eval sandbox that has no usage history.
- Whether the `claude -p` skill-triggering bug in the skill-creator loop is fixed in current versions.
- Exact methods in tinyBenchmarks, the Hsu & Shekhar confidence-sequence paper, and CONSOL. I read abstracts and overviews only.
- Community routing-classifier and "~25% negatives / 90% target" heuristics. These come from third-party blogs.
- A note on Miller's paired-difference worked example: the WebFetch summary flagged an internal inconsistency in it ("1/6 to 1/9" vs the formula). I did not use that number.
