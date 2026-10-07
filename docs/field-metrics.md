# Field metrics

When a Claude Code session ends, myspec records how the session went: one JSON line for each skill run and one for the session as a whole. You can then see which skills are slow, which are expensive, which get blocked, and which keep looping. The file stays on your machine. Nothing is uploaded, and no prompt, message, file content or tool input is stored.

## Where it lives

`.claude/state/metrics/runs.jsonl` in the main checkout. A session that ran in a linked worktree records there too. `.claude/state/` is gitignored per-checkout state: `init` and `update` add the line to `.gitignore`. As a second guard, the scan asks `git check-ignore` before it writes, and refuses with one stderr line when the file would be tracked.

The `record-session-metrics.sh` hook writes it. The hook is registered under `SessionEnd` by `init`, and `update` wires it into existing projects. The hook starts `friction-scan --emit` in the background and returns straight away, so session exit does not wait. The scan runs under a 30-second cap. If it fails or is killed, it records nothing and prints nothing. It writes all its lines in a single append, so it never leaves half a record.

## Reading it

```bash
node "${CLAUDE_PLUGIN_ROOT}/lib/friction-scan/stats.mjs"               # last 30 days
node "${CLAUDE_PLUGIN_ROOT}/lib/friction-scan/stats.mjs" --since=7d --json
```

```
myspec field metrics, since 2026-08-30: 41 sessions, 96 skill runs (.claude/state/metrics/runs.jsonl)

Sessions: active p50 38m, tokens p50 9.8M in / 71k out, 12 fix rounds

| Skill | Runs | Active p50 | Active p90 | Tokens in p50 | Tokens out p50 | Blocked | Fix rounds | Hook blocks |
|---|---|---|---|---|---|---|---|---|
| myspec:feature-implement | 6 | 41m | 1h52m | 21.4M | 96k | 1/6 | 9 | 4 |
| myspec:feature-plan | 5 | 12m | 19m | 3.1M | 28k | 0/5 | 0 | 0 |

Hook blocks: isolation-undecided 14, reuse-audit 5
```

- **Active** time counts only the gaps of five minutes or less between transcript entries, as in the friction report.
- **Tokens in** is input plus cache reads plus cache writes, because cache reads dominate a long session. **Tokens out** is output only.
- **Blocked** is the number of runs in which a subagent ended on `**Status:** BLOCKED` or `PROBES_BLOCKED`.
- **Fix rounds** is the number of extra prompts the controller sent to subagents it had already dispatched.
- **Hook blocks** counts the distinct turns a hook blocked. Known myspec hooks appear under their signature id (see [friction-report.md](friction-report.md)); any other hook appears under its script name.

`/myspec:doctor` runs the summary when the file exists and passes it to the hooks and skills audits.

## Record schema (`schema: 1`)

| Field | In | Meaning |
|---|---|---|
| `schema`, `kind` | both | `1`; `skill` or `session` |
| `id`, `session` | both | `<session id>:<window anchor>` / `<session id>:session`; the Claude Code session id |
| `myspec`, `cc` | both | `frameworkVersion` from `.myspec.json`; the Claude Code version from the transcript |
| `start`, `end`, `active_ms` | both | Window bounds (ISO) and active time |
| `skill`, `trigger` | skill | Skill name as the harness recorded it; `user-slash`, `model`, `nested` or `subagent` |
| `feature` | skill | The skill's first argument, only when it names an existing `${aiDir}/features/<slug>/` directory; else `null` |
| `turns` | both | Prompts the user typed or queued inside the window. Background-task notifications, the compaction summary, and messages from other agents are not turns |
| `tools` | both | Tool calls by tool name; MCP tools by server (`mcp__<server>`) |
| `subagents` | both | Subagents dispatched (Agent/Task calls, and Skill calls run as a forked agent); for a session, subagent transcripts |
| `tokens` | both | `{in, out, cache_read, cache_write}` from `message.usage`, counted once per message id, including dispatched subagents |
| `hook_blocks` | both | `{<signature or script>: turns}` |
| `fix_rounds`, `subagent_status` | both | Extra prompts to dispatched subagents; their final verdicts by word (`DONE`, `BLOCKED`, `NEEDS_CONTEXT`, `PROBES_FAILED`, …) |
| `reason`, `model`, `skills` | session | The SessionEnd reason, the model used most in the main thread, and the number of skill records |

**Skill windows.** A window opens when a skill starts, either from a `/skill` command or a `Skill` tool call. It runs until the next skill starts or the transcript ends.
- A `Skill` call inside an open window counts as `nested` when the user has not typed since that window opened. A nested skill closes only the nested skill before it, so the parent's counts include its nested skills.
- A skill the model starts after the user has typed is top-level (`model`), and it closes the window before it.
- Conversation between skills belongs to the window before it. `turns` shows how much there was.
- Only the user's own turns end a nested run. A background job finishing, auto-compaction, and a message from another agent do not.

**Idempotency.** A record is skipped when a record with the same `id` and `end` is already in the file. Running the scan twice on the same session adds nothing. A resumed session that grew adds newer records for the windows that changed, and `stats.mjs` keeps only the latest record for each `id`.

## Turning it off

Recording is on by default. Any one of these turns it off:

| Where | Setting |
|---|---|
| Per project, in `.myspec.json` | `"feedback": { "metrics": false }` |
| Per shell | `MYSPEC_DISABLE_METRICS=1` |
| Per shell, cross-tool | `DO_NOT_TRACK=1` (any value but empty, `0`, `false` or `FALSE`) |

A `.myspec.json` that does not parse also counts as opted out, so a hand-edited `"metrics": false` with a syntax error still holds. `"frictionReport": false` is a separate switch. It turns off the friction report, not recording. To remove what has been recorded, delete `.claude/state/metrics/`.

**Why on by default.** The records never leave the machine, hold no content, and cost no tokens. The hook adds nothing to session exit because the scan runs in the background. Opt-in field data stays close to empty, and an empty file cannot tell anyone which skill is slow. The upload-style telemetry this is often compared to (OpenSpec, Homebrew, Next.js) is opt-out with an environment kill switch. myspec is stricter than that: it never uploads, and it honours `DO_NOT_TRACK`.

## Running it by hand

```bash
node "${CLAUDE_PLUGIN_ROOT}/lib/friction-scan/scan.mjs" --session=<session_id>[,<resumed_session_id>...] --emit
node "${CLAUDE_PLUGIN_ROOT}/lib/friction-scan/scan.mjs" --transcript=<path/to/session.jsonl> --emit=<file.jsonl> --json
```

A resumed session continues under a new id. Give every id of the chain, comma-separated, and the chain is recorded as one session under the first id, with an entry repeated across transcripts counted once. `--emit` with no path writes the default file, and only in a project that has `.myspec.json`. `--emit=<path>` writes to that path. It always exits 0. A skipped or failed run prints one line on stderr, and `--json` prints `{"written","skipped","path"}`.

## Limits

- **Claude Code only.** The transcript format is internal to Claude Code and is not a documented API. An unrecognized transcript is skipped rather than guessed at.
- **Window boundaries are a heuristic.** See *Skill windows* above.
- **A transcript over 256 MB is skipped.** Smaller ones are streamed line by line, and each entry is cut down to the fields a record needs, so memory does not grow with the size of file contents in the transcript.
- **Transcripts are pruned** after Claude Code's `cleanupPeriodDays`, so a session older than that cannot be recorded later by hand.
- **The file grows without limit.** Each record is about 0.5 KB. Delete the file whenever you like.

## Going further: Claude Code OpenTelemetry

For cost in dollars, per-request latency, tool durations and cross-machine dashboards, use Claude Code's own OpenTelemetry export. myspec does not turn it on, and cannot: Claude Code ignores the OpenTelemetry exporter variables in a repository's `.claude/settings.json` and `.claude/settings.local.json`. Set them in your shell, in the `env` block of `~/.claude/settings.json`, or in managed settings.

```bash
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export OTEL_LOGS_EXPORTER=otlp            # events: skill_activated, hook_execution_complete, …
export OTEL_METRICS_EXPORTER=otlp         # counters: cost, tokens
export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
export OTEL_EXPORTER_OTLP_ENDPOINT="$YOUR_COLLECTOR_URL"   # your OpenTelemetry collector
export OTEL_LOG_TOOL_DETAILS=1            # needed to see myspec skill names
```

- **`OTEL_LOG_TOOL_DETAILS=1` is what makes the data about myspec.** Without it, Claude Code redacts plugin skill names (`skill.name` is `third-party` for a plugin skill, `custom_skill` for a project skill), and the cost and token counters carry no skill, agent or plugin names. The flag also logs Bash commands and tool inputs, so point `OTEL_EXPORTER_OTLP_ENDPOINT` only at a collector you control.
- **Useful events:**
  - `claude_code.skill_activated`: `skill.name`, and `invocation_trigger` = `user-slash` / `claude-proactive` / `nested-skill`. The share of `claude-proactive` activations for each skill measures whether its description triggers in the field.
  - `claude_code.hook_execution_complete`: `num_blocking` per `hook_name`.
  - `claude_code.subagent_completed`: `total_tokens`, `total_cost_usd`.
  - `claude_code.api_request`: `cost_usd`, `input_tokens`, `output_tokens`.
- **Keeping it local.** Run an OpenTelemetry collector with a file exporter and point `OTEL_EXPORTER_OTLP_ENDPOINT` at it.
- **Prompt content** stays redacted unless you also set `OTEL_LOG_USER_PROMPTS=1`.

The full reference is Claude Code's [monitoring documentation](https://code.claude.com/docs/en/monitoring-usage).
