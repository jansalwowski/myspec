# Friction report

When a session is archived, `/myspec:session-complete` scans the session's Claude Code transcripts and reports friction that repeated: the same hook blocking again and again, hooks that could not run, subagents that got stuck or needed context, subagents sent back for several fix rounds. Each row names an owner, so you can tell whether to fix something in your project, refresh your myspec install, or open an issue against myspec.

The scan is a deterministic script (`lib/friction-scan/scan.mjs`). It makes no model calls, adds nothing to prompts, and writes no files. Nothing leaves your machine. The same script, run with `--emit` by a `SessionEnd` hook, records local per-skill field metrics: see [field-metrics.md](field-metrics.md).

## Reading the report

```
friction-scan: session 9f3c2a71, 2h05m active, 11 subagents

| Pattern | Owner | Count | Ref | Detail |
|---|---|---|---|---|
| hook block: memory-conformance | myspec | 4 | hooks/verify-before-stop.sh | Memory conformance check failed for changes under ai/memory. … |
| hook not found: mark-code-changed.sh | setup | 22 | hooks/mark-code-changed.sh | registered in settings but the script is missing: run /myspec:update |
| subagent-needs-context | project | 1 | - | Implement Task 4 |

Slowest subagents: Implement Task 3 (24m); Phase 2 review (11m); Implement Task 4 (9m)

1 row(s) look framework-side (owner myspec).
1 row(s) point at this project's myspec install (owner setup): run /myspec:doctor or /myspec:update.
```

A session with nothing above threshold prints nothing. That is the normal case.

"Active" time counts only gaps of up to five minutes between transcript entries, so a session resumed the next day does not read as 20 hours of work.

## Owners

| Owner | Means | What to do |
|---|---|---|
| `myspec` | A myspec hook or gate kept stopping the agent on the same thing | Likely a framework issue. Open an issue against myspec with the row and the myspec version. |
| `setup` | Your project's myspec install drifted (a registered myspec hook is missing, or the setup conformance check failed), or a command a myspec hook calls, such as `jq`, is missing on this machine | For a missing hook, run `/myspec:update`, then `/myspec:doctor`. For a missing command, install it. |
| `harness` | Claude Code itself refused, e.g. its worktree guard | Neither myspec nor your project. Report it to Claude Code if it keeps happening. |
| `project` | Your checks failed, your own hook is missing, or a subagent needed context the spec or plan did not give | Fix it in your project: the test, the hook config, the spec |
| `unknown` | The transcript alone cannot say whose it is | Read the Detail. `unknown` is an answer, not a gap to fill: the skill does not guess. |

## Rules

Owners come from fixed rules, not from a model reading the transcript. A confident wrong owner would send you to the wrong repo.

| Pattern | Reported when | Owner |
|---|---|---|
| Block from a myspec hook with a known message | The same message blocks 3 or more times | Per the signature table below |
| Block from a myspec hook with an unknown message | 3 or more times | `unknown` |
| Block from another hook | 3 or more times | `project` (or `unknown` if the hook's command is not recorded) |
| Registered hook missing (exit 127, and stderr names the script itself) | Once | `setup` for a myspec hook, else `project` |
| myspec hook exits 127 because a command it calls is missing (`<script>: line 12: jq: command not found`) | Once | `setup` |
| myspec hook crashed (other non-zero exit) | Once | `myspec` |
| Claude Code refusal | 3 or more times | `harness` |
| The same tool error | 3 or more times | `unknown` |
| Subagent final `**Status:** BLOCKED` / `PROBES_BLOCKED` | Once | `unknown` |
| Subagent final `**Status:** NEEDS_CONTEXT` / `PROBES_FAILED` | Once | `project` |
| Subagent continued by the controller 3 or more times | Once | `unknown` |

A single block is never reported. The isolation prompt on the first edit of every session is the hook doing its job.

Counts are distinct assistant turns, not tool results. Three edits sent in parallel and denied together by the isolation hook count once.

A tool result counts as a hook block only when it opens with the hook's reason. A failing test run or a `grep` that prints a hook message further down stays a tool error. Subagent verdicts count only on a line of their own, so a report mentioning an earlier `PROBES_FAILED` is not a failure.

Known myspec hook messages:

| Signature | Hook | Owner |
|---|---|---|
| `isolation-undecided`, `isolation-mismatch` | `require-isolation-decision.sh` | `myspec` |
| `branch-guard` | `guard-worktree-context.sh` | `myspec` |
| `reuse-audit` | `require-reuse-audit.sh` | `myspec` |
| `memory-conformance`, `worktree-provisioning` | `verify-before-stop.sh` | `myspec` |
| `setup-conformance` | `verify-before-stop.sh` | `setup` |
| `absolute-paths` | `no-absolute-paths.sh` | `unknown` (usually the model's own write) |
| `frontmatter` | `validate-frontmatter.sh` | `unknown` (usually the model's own write) |
| `project-verification` | `verify-before-stop.sh` | `project` |

## Turning it off

Per project, in `.myspec.json`:

```json
{ "feedback": { "frictionReport": false } }
```

Per shell: `MYSPEC_DISABLE_FRICTION_REPORT=1`.

It is on by default because it runs once per archived session, locally, at no token cost.

## Running it by hand

```bash
node "${CLAUDE_PLUGIN_ROOT}/lib/friction-scan/scan.mjs" --session=<session_id>
node "${CLAUDE_PLUGIN_ROOT}/lib/friction-scan/scan.mjs" --transcript=<path/to/session.jsonl> --json
```

The session id is in the session log's frontmatter. The opt-out is read from `.myspec.json` at the checkout root, so running from a subdirectory still honors it. With `--json`, a turned-off scan prints `{"disabled":true,"findings":[]}`. `--session` looks in `$CLAUDE_CONFIG_DIR/projects/`, else `~/.claude/projects/`; `--projects-dir` overrides that. `--json` prints every finding with its first timestamp and the transcripts it came from.

| Exit | Meaning |
|---|---|
| 0 | Scanned (prints nothing when nothing crosses a threshold), or turned off |
| 1 | Usage error, including an empty `--session=` |
| 2 | No transcript found for the session |
| 3 | Transcript format not recognized |

The report shortens home-directory paths to `~` (only at a path boundary), but Detail can still quote file names and error text from your project. Read it before pasting it into a public issue.

## Limits

- **Claude Code only.** A session with no transcript prints one "skipped" line.
- **The transcript format is internal to Claude Code**, not a documented API. A shape the scanner does not recognize exits 3 instead of giving a wrong answer.
- **Transcripts are pruned** after Claude Code's `cleanupPeriodDays` (30 by default), so a session older than that cannot be scanned.
- **Fix rounds are a heuristic.** They count plain prompts a subagent received after its first one, skipping Claude Code's own injected messages (isMeta entries such as a forked skill's body, and the auto-compaction summary). A controller's SendMessage continuation counts. Resumed and background subagents have not been checked against this.
- **What only a subagent saw** (an ambiguous instruction, a gate it could not meet) is not in the transcript as structure, so it is not reported.

## For maintainers: adding a hook

`lib/tests/friction-scan.test.sh` pins the scanner to the hooks:

- `MYSPEC_HOOKS` in `scan.mjs` lists exactly the scripts in `hooks/`. When a hook is renamed, keep the old name there too (with a test exception, since it has no script) until the upgrade floor passes the release whose `update` unwires it: installs below that release still register it. Past the floor, drop it. `guard-git-branch.sh`, unwired by the 2.0 `update`, was dropped in 3.0, whose floor is 2.12.
- Every `HOOK_SIGNATURES` entry must be a literal substring of its hook's source. When you change a block message, update the signature in the same PR.

A new blocking hook needs a signature row to be attributed. Without one, its repeated blocks are still reported, as `unknown`.
