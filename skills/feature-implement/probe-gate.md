# Milestone Probe Gate

Read from SKILL.md Step 4b (b), before dispatching the probe executor. It applies only when the milestone carries a `**Checkpoint probes:**` block. `<plugin lib>` is the path SKILL.md resolves.

## Dispatch

Dispatch the plugin agent `myspec:probe-executor` (Agent tool, `subagent_type: "myspec:probe-executor"`, `mid` tier) — never general-purpose, which keeps the edit tools the executor's definition removes. One executor per milestone, `mixed` included, so probes run in plan order.

Its prompt is the payload and nothing else:

- the `**Checkpoint probes:**` block, verbatim and whole
- the checkout's absolute path, with `BASE_SHA`
- the artifact directory (`ART`, below)
- the Target override: an address the user gave for a `NEED:` line, else "none"
- the scratch-env script: `"<plugin lib>/myspec-config.sh" get probes.scratchEnvScript`, unquoted, or "none" when it prints `null`, so every probe run reuses the project's provisioning instead of rebuilding the scratch database, cache and buckets by hand

Never the spec rationale, the plan's reasoning, implementer reports, phase verdicts, or your view of the milestone.

Create the artifact directory before each dispatch, under the restart-safe, gitignored run state rather than `mktemp`, so the artifact paths in the Execution Log still open after a restart; each dispatch gets the next free `run-R`:

```bash
"<plugin lib>/implement-state.sh" probe-run {feature} N
```

It prints the new `$STATE/probes/milestone-N/run-R/` path (`ART`).

The executor loads no project CLAUDE.md, so what the target needs to start must be on the Target and Scratch env lines; a gap comes back as a `NEED:` line.

## Reading the report

You never run, reword, or drop a probe yourself: the agent that did the work must not be the one that decides whether its verification ran, and tests green is not a substitute. Copy each probe line into the Execution Log as `Probe (Milestone N): …`.

The gate passes only on `PROBES_PASSED`, with an observed value and artifact on every line. A missing report counts as BLOCKED, and FAIL or BLOCKED is a hard stop — ask the user, putting each of the report's `NEED:` lines to them first:

- **fix** → run the finding through the Step 4d fix loop (or, for a `NEED:` line, get what it names from the user), then re-dispatch the executor with the same probes, the next `run-R` directory, and any Target override the user gave
- **waive <P|D><n>** → log `Waiver (Milestone N): …`; the probe stays unrun, and the completion report says so
- **stop** → as in Step 4b (c)
