# claude plugin eval: research notes

Researched 2026-10-07. Local build: Claude Code 2.1.293. No evals were run.
Legend: [DOC] stated in official docs, [HELP] from local --help output, [INFER] my inference, [UNVERIFIED] not confirmed by docs or help.

## Sources
- https://code.claude.com/docs/en/plugin-evals.md ("Test plugins with evals"), main source
- https://code.claude.com/docs/en/plugins/cli-reference.md (section "plugin eval" and "plugin eval init")
- https://code.claude.com/docs/en/plugins/measure.md (plugin cost, `claude plugin details`)
- https://code.claude.com/docs/en/prompt-caching.md
- https://code.claude.com/docs/en/skills.md (skill listing, /skill-doctor, descriptions)
- https://code.claude.com/docs/en/costs.md
- https://code.claude.com/docs/en/cli-reference.md (--max-budget-usd, --max-turns, --exclude-dynamic-system-prompt-sections)
- Local: `claude --version`; `claude plugin eval --help`; `claude plugin eval init --help`; `claude plugin --help`

## 1. Requirements and availability
- [DOC] Claude Code v2.1.269+; git 2.31+ if git is installed (older git stops the run).
- [HELP] Local build 2.1.293 prints full help, so the command is available here.
- [DOC] Each eval run and each judge grader is a real model call on the user's account.

## 2. Flags (`claude plugin eval [target]`, [HELP])
| Flag | Default | Notes |
|---|---|---|
| target | cwd | path, installed name, `name@marketplace`, `name@skills-dir`, or a single prompt.md/case.yaml [DOC] |
| `--runs <n>` | case `runs`, else 3 | per case per arm; schema allows 1-50 [DOC] |
| `-j, --concurrency <n>` | 1 | 1-8; shares one rate limit; case order kept |
| `--model <model>` | case `model`, else ANTHROPIC_MODEL if set, else Claude Code default [DOC] | see discrepancy D2 |
| `--judge-model <model>` | see D1 | used by llm and baseline graders |
| `--ablation none\|with-without` | per case: with-without when a plugin resolves | see section 7 |
| `--threshold <0..1>` | 1.0 | case passes if with-arm score >= threshold |
| `--max-cost-usd <usd>` | none | checked before each run starts; in-flight runs finish; exit 2 with partial results |
| `--case <glob>` | all | filter by case name |
| `--tag <tag...>` | all | repeatable; case runs if any tag matches |
| `--allow-tools <tools...>` | read-only set only | grants Bash, Write, Edit, WebFetch, WebSearch, mcp__*; supports `Tool(pattern)` |
| `--scaffold` / `--no-scaffold` | off | runs author-supplied scaffold_script as the user, outside the agent sandbox |
| `--mocks record\|off` | record | off = start real MCP servers |
| `--allow-real-servers` | off | with record, start real servers for unmocked servers |
| `--eval-dir <dir>` | manifest `experimental.evals`, else `evals` | results go to `<dir>/results/` |
| `--output-dir <dir>` | `<eval dir>/results/<timestamp>/` | |
| `--json [path]` | off | quiet run; prints result doc or writes .json file; put target before it |
| `--report <path>` | results dir | HTML report location |
| `--no-publish` / `--publish-report` | publish when account supports it | |
| `--trust-plugin` | off | skip trust prompt; needed for CI |
| `--keep-temp` | off | keep sandbox dirs |
| `--verbose` | off | per-message trace to debug log |

`init` ([HELP]/[DOC]): `claude plugin eval init [name]`. Default is an interactive interview in a terminal. `--bare <name>` writes a blank template (prompt.md + graders/criteria.md). `--eval-dir <dir>`. `-i/--interactive` requires a terminal. Running it from inside a session prints interview instructions instead of writing a template [DOC].

Exit codes [DOC]: 0 all cases >= threshold; 1 below threshold, case load error, no cases, run could not start, untrusted dir without --trust-plugin, bad option; 2 partial (cost ceiling or credential rejected); 130 interrupted; 143 terminated.

## 3. Case format
Layout: `evals/<case>/prompt.md`, `evals/<case>/graders/<name>.md`, optional `case.yaml`, optional `mocks/`. A case without at least one grader fails to load. Nest cases under a non-case directory to group them.

prompt.md frontmatter [DOC], unknown keys are errors:
| Field | Default | Purpose |
|---|---|---|
| schema_version | "1.1" (auto) | |
| name | dir name | `--case` matches it |
| description, expected_outcome | none | human only |
| tags | [] | `--tag` |
| plugins | nearest enclosing plugin | relative paths, e.g. `["../.."]` |
| runs | 3 | 1-50 per arm |
| model | child default | |
| max_turns | 10 | up to 200; hitting it is a run error, usually lowers score |
| timeout_seconds | 300 | up to 3600 |
| allowed_tools | [] | read-only tools only: Read, Glob, Grep, NotebookRead, Skill, AskUserQuestion, Agent, TodoWrite, Task* |
| append_system_prompt | none | appended to child system prompt |
| env | {} | keys must match `EVAL_[A-Z0-9_]*` |

case.yaml (requires `schema_version: "1.1"` and `name`). Top-level: description, tags, plugins, runs, expected_outcome. Under `execution:`: model, max_turns, timeout_seconds, allowed_tools, append_system_prompt, env. Case-only fields:
- `context.scaffold_script` (bash, runs only with --scaffold, 120 s limit, minimal env)
- `context.history_file` (.jsonl transcript to resume; prompt becomes next user turn)
- `context.add_dirs` (read-only dirs inside case dir)
- `execution.prompt` (prompt inline when prompt.md is omitted)
- `graders` (list; each with name plus grader keys; llm rubric goes in `criteria`)

Grader frontmatter [DOC]: `type` (required), `weight` (default 1, positive number), `arm` (`with-only` excludes from scoring in a two-arm run; `both` forces scoring).

What a grader reads (`target` for regex, `focus` for llm) [DOC]: `last_message` (default), `trace` (JSON per line; regex sees all messages, llm judge sees first 12 and last 12), `files` (paths created during the run, not contents), `{source: file, path}` (contents of a workspace file; PNG/JPEG/GIF/WebP shown to llm judge as image; other binaries refused), `mock_calls`.

## 4. Grader types [DOC]
| Type | Options | Passes when | Costs a model call |
|---|---|---|---|
| regex | pattern, flags, match (contains / not_contains / count:N), target | JS regex found in target; `flags: i` for case-insensitive, no inline (?i) | no |
| tool_used | tool, input_match, min (default 1), max (default unlimited) | count of matching calls in [min,max]; "never call" = min 0, max 0 | no |
| tool_order | before, after | first `before` call precedes first `after` call | no |
| file_exists | path (glob), exists | a file created during the run matches; exists:false inverts | no |
| llm | criteria, focus | judge votes PASS in >= 2 of 3 votes | yes (3 short calls) |
| baseline | baseline_file (.jsonl in case dir), criteria | judge finds run at least as good as reference transcript | yes |
No custom-code graders [DOC].

## 5. Scoring
- [DOC] Run score = weighted fraction of graders passed. Case score = mean across runs. Case passes at >= threshold.
- [DOC] Suite cost in calls ~ cases x runs agent runs, doubled for baseline arm, plus 3 judge calls per llm/baseline grader per run.
- [DOC] Results: `aggregate-result.json` (`schemaVersion: 1`, camelCase, additive) with `aggregates.overallScore`, `casesPassed/casesTotal`, `meanDelta`, `cases[].aggregates.score/delta`, `arms.with|without[].error/aborted/skippedPaidGraders`, `costUsd` (list-price estimate incl. judge calls), `durationSeconds`, `claudeVersion`, `partial`, `partialReason`.

## 6. Cost of one run
What one run contains [DOC]:
- A fresh, isolated `claude -p` child session in a temp workspace, with fresh HOME and CLAUDE_CONFIG_DIR. Only the plugin under test is loaded. User settings, hooks, CLAUDE.md, MCP servers, memory, and other plugins are absent.
- Claude Code's default system prompt and tool definitions are present in each request [INFER: standard for any `claude -p` child; eval doc does not state token totals].
- Skill listing: names and descriptions of the plugin's skills are in context on every turn while the plugin is enabled [DOC, measure.md: "Every session where a plugin is enabled includes the names and descriptions of its skills, agents, and commands"]. Description + when_to_use is truncated at 1,536 chars in the listing [DOC, skills.md]. Full skill body loads only when invoked [DOC].
- Each turn re-sends context; within one run, later turns read the prefix from cache [DOC prompt-caching.md, general mechanism].
- Per-run dollar cost: not published. The one figure in docs is an illustrative quickstart ($0.41 for 1 case, 6 runs, "WITH 1.00 / W/OUT 0.33") [DOC, illustrative only, not a benchmark].
- Get the real number for a plugin: `claude plugin details <name>` shows "Always-on" token cost and per-component cost [DOC measure.md]. [UNVERIFIED] whether `details` makes any model call; docs call the counts estimates and do not say it is offline.

## 7. Prompt caching across runs
- [DOC] Cache is prefix-matched. Scope: "effectively scoped to one machine and directory". Two sessions in different directories build different prefixes and miss each other's cache. The system prompt embeds auto memory paths and the conversation opens with cwd/platform/shell/OS. [DOC prompt-caching.md "Cache scope"]
- [INFER] Each eval run uses a new temp workspace and HOME, so cwd and memory paths differ between runs. Expect little or no cross-run cache sharing. Within a run, turns do hit cache.
- [DOC] `--exclude-dynamic-system-prompt-sections` moves per-user context out of the system prompt so cache can be shared across users/machines. Only for `-p` scripted workloads [DOC cli-reference.md]. [UNVERIFIED] whether `claude plugin eval` passes this flag internally. Nothing in eval docs says so.
- [DOC] Cache TTL: main conversation gets 1h on a subscription within plan usage, else 5 min. Subagents/judge calls: 5 min by default. `promptCacheTtl` setting / `CLAUDE_CODE_PROMPT_CACHE_TTL` env to change. [DOC prompt-caching.md]
- [DOC] Plugin eval does not mention prompt caching anywhere.

## 8. Result caching, early stop, reuse
- Result caching of agent runs: none documented. Each invocation writes a new `results/<timestamp>/`. [DOC]
- Only replay: agent-mock answers (`type: agent` mocks) recorded in `mocks/.replay/<server>/` answer identical calls with no model call. This replays MCP tool answers, not the agent under test. [DOC]
- Early stop: none documented for runs. A run ends at task finish, max_turns, or timeout_seconds. Max_turns and timeout are recorded as run errors. [DOC]
- Early stop on skill invocation: not documented. [UNVERIFIED] assume the run continues to completion.
- Cost ceiling: `--max-cost-usd` stops launching new runs once spend reaches the cap; in-flight runs finish, so spend can overshoot by up to the concurrency count; exit 2. When a run breaches, paid graders (llm/baseline) are skipped; free graders still score [HELP, DOC].

## 9. Cheaper trigger-only testing
No trigger-only mode is documented. Options that exist:
1. `claude plugin details <name>`: static always-on cost of the skill listing [DOC].
2. `claude plugin validate <path>`: structure/schema check only, no behavior [DOC plugin-evals intro].
3. `/skill-doctor` (in session) or `/plugin` Stats tab: usage and never-invoked flags from real local sessions, no new model calls [DOC skills.md]. Note it reports on your own sessions, not on test runs.
4. Narrow run: `claude plugin eval . --case <name> --runs 1 --ablation none` - one arm, one run, judge calls only if llm graders exist [DOC].
5. Use only deterministic graders (`tool_used`, `regex`) to avoid judge calls [DOC cost guidance].
6. skill-creator plugin: should-trigger / should-not-trigger prompt sets with hit-rate measurement [DOC skills.md]. Still runs the model; uses its own `evals/evals.json`, not compatible with plugin eval.
7. Direct `/skill-name` tests the skill body, not whether it triggers [DOC skills.md].
Caution: do not set `max_turns` very low to cut cost, because hitting it is a run error and lowers the score [DOC].

## 10. Batching
- [DOC] `-j/--concurrency 1-8`. Parallel agent runs share one account rate limit. Results keep case order.
- [HELP] Target is a single positional. Multiple cases: one `--case` glob, or repeatable `--tag` (any match). Multiple plugins: separate invocations [INFER from single-target syntax].
- [DOC] `--runs` 1-50 per arm per case.
- Batching across plugins in CI: shell loop, each with its own `--output-dir` or `--json` path [INFER].

## 11. --ablation
- `none`: one arm (with plugin). Halves agent-run cost. Table shows SCORE and PASS% instead of WITH / W/OUT / Delta [DOC].
- `with-without` (default when a plugin resolves): repeats the same runs with no plugin loaded. Delta = with-arm score minus without-arm score [DOC].
- [DOC] Graders excluded from the score in two-arm mode (reported as `scored: false`, pass/fail indicators only):
  - every `tool_used` grader with `tool: Skill` (the "was the skill invoked" check)
  - `regex` with `target: mock_calls` and `llm` with `focus: mock_calls`, when all mocked servers belong to the plugin
  - any grader with `arm: with-only`
- [DOC] Overrides: `arm: both` forces scoring in both arms (use for "must not call the skill" with min 0 max 0). If every grader is excluded, they are scored normally. `--ablation none` excludes nothing.
- [DOC] Single-arm by default: cases with `context.history_file` when target is a path; cases where the plugin could not be resolved (add `plugins: ["../.."]`).
- Implication: in the default with-without mode, a `tool_used: Skill` grader does not move the score. To score activation in a delta run, add `arm: both` or use `--ablation none`.

## 12. Discrepancies and unverified items
- D1 Judge default: `--help` says "default: haiku"; docs say the judge is "the model Claude Code uses for background tasks". [HELP] vs [DOC] disagree. Pin `--judge-model` in CI.
- D2 ANTHROPIC_MODEL: docs say `--model` falls back to ANTHROPIC_MODEL if set. The embedded reference in the system prompt says ANTHROPIC_MODEL is not inherited. Unresolved. Pin `--model` to avoid the question.
- D3 Cost figures in docs (e.g. $0.41) are illustrative, not measured per-run costs.
- U1 Exact system prompt and tool-definition token count per run: not documented.
- U2 Whether eval passes `--exclude-dynamic-system-prompt-sections` internally: not documented.
- U3 Whether `claude plugin details` makes a model call: not stated.
- U4 Early stop when a Skill call happens: not documented.
- U5 Whether `--allow-real-servers`/`--mocks` change caching: not documented.
- Version note: docs state v2.1.269+; the 2.1.293 help output matches. `/skill-doctor` requires v2.1.252+ [DOC skills.md].
