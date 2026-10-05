# Stop-gate checks that escape the cap

Design for issue #147, generalized. `verify-before-stop.sh` (the runner is `lib/stop-gate/run.sh`) caps each check at 120 s and, since #116, kills the check's process group at the deadline. The cap is only as good as what the group kill reaches.

## What escaped (measured, cap lowered to 3 s)

| Escape | Hook wait before | Left running |
|---|---|---|
| Passing check leaves a background child (`server &`) | as long as the child, cap ignored | yes |
| Grandchild leaves the group (`setsid`, a detaching daemon) | as long as the grandchild | yes |
| Remote execution: `docker exec`, `docker compose exec` (same mechanism: `kubectl exec`, `ssh`) | 3 s | yes, in the container |

The first two defeat the cap: the hook captured output with `$(...)`, which waits for every holder of the pipe. The third leaves one more full run per capped stop, and those overlap (#147 measured 122 s alone, 306 s with a leftover run).

Rejected: a host-side sweep for processes carrying a tagged environment variable. macOS `ps` does not show other processes' environments, so it is not portable. A documented `trap` wrapper alone: it only gets the hook's 5 s TERM-to-KILL grace, and every project would need to copy the boilerplate correctly.

## Design

1. **Output goes to a file, not a pipe, one file per run.** The hook's wait is then bounded by the cap whatever escapes, and a detached process that keeps writing cannot reach a later check's report.
2. **When a check exits on its own, the rest of its group gets TERM, then KILL after 2 s.** This holds with perl and with the GNU `timeout` fallback, which leads its own group; with neither, the check runs uncapped and nothing is reaped. Leftovers of a finished check are orphans. Daemons meant to persist (Gradle, Nx and the like) start their own session and are untouched.
3. **`MYSPEC_CHECK_RUN_ID`** is exported to each check, unique per run.
4. **Optional `checks[].cleanup`.** It runs only after a timeout, since a check that exited on its own took its remote work with it. It runs outside the killed group, with the same `MYSPEC_CHECK_RUN_ID` and its own cap: 30 s, lowered with `MYSPEC_CHECK_CAP_SECONDS`, never raised.
5. **The timeout report says what happened to the leftover work.** It reads "Cleanup ran", "Cleanup failed (exit N)" with its output, or "Cleanup timed out". With no cleanup declared, it says work in a container, on another host or detached may still be running, and to confirm it stopped before re-running.
6. **Doctor surface E** flags a required check that reaches a container or another host, directly or through a script, without `cleanup`.
7. **Skills that run checks themselves** (feature-implement's controller and phase reviewer, feature-complete) export a run ID per check and run `cleanup` after they kill a check or it times out.

The cleanup pattern for a container-run check is in README.md. The exec'd shell records `$$` in a file named after the run ID; cleanup runs `kill -TERM -<pid>`. That shell leads its own group in the container. Omit `--`, which BusyBox `kill` rejects.

## Gate-wide budget (R13)

The per-check cap bounds one check, not the stop. Five checks in two armed checkouts could take 10 × 150 s, and past the harness's own hook timeout the harness cancels the hook and discards its output, so the stop proceeds with no decision at all. Claude Code's hooks reference gives the `timeout` field as "Seconds before canceling", with "Defaults: 600 for `command`"; the lower 30 s default applies only to `UserPromptSubmit`, `PreModelSwitch` and `PostModelSwitch`, and on a timeout it "cancels a `command` … hook that reaches its `timeout`, discarding the hook's output" (https://code.claude.com/docs/en/hooks, read 2026-10-03; docs.claude.com/en/docs/claude-code/hooks redirects there). So the Stop gate's default budget is 300 s, half of that, and the plugin's `hooks.json` (the only wiring since 3.0) sets the Stop entry's `timeout` to 330 s: the budget plus 30 s for the last kill grace (5 s), a cleanup's floor (5 s) and the report. `MYSPEC_GATE_BUDGET_SECONDS` lowers the budget; a value at or above 300 is ignored. When the budget runs out, the running check is capped at what is left and the rest are reported "not run", which blocks: a check that did not run is not a pass.

## Verification

`hooks/tests/verify-before-stop-timeout.test.sh` covers:
- a passing check's leftover child is killed and does not hold the hook;
- a `setsid` grandchild at timeout does not hold the hook;
- cleanup gets the run ID;
- cleanup success, failure and timeout are each reported;
- cleanup never runs for a check that exited on its own;
- a budget spent after check 1 of 3 blocks and names checks 2 and 3, and the budget cannot be raised (`lib/tests/stop-gate-run.test.sh` holds the function-level cases of all of the above).

Docker was verified by hand through the real hook, because CI has no daemon. Without `cleanup`, three processes survived in the container. With the README pattern, none did, and the hook returned in 4 s.

## Compatibility

`cleanup` is optional, and a check without it behaves as before except for item 2: a check that leaves a process in its own group now has it killed. That is the cap's intent applied to a normal exit, not a RELEASING.md breaking change. No schema, manifest or contract heading changes.
