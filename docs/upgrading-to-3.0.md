# Upgrading to myspec 3.0

Stub, filled in when the major is cut (RELEASING.md, "Cutting the major"). It
lists what 3.0 drops and the breaking changes still pending in the
[v3.0.0 milestone](https://github.com/jansalwowski/myspec/milestone/1).

## Before you start

3.0 upgrades from **2.12.0 or later** (RELEASING.md, "Upgrade base"). `update`
refuses a lower version: check out the plugin at tag `v2.12.0`, start Claude
with `--plugin-dir` pointing at that checkout, run `/myspec:update`, then return
to the current plugin. A project still on 1.x goes through `v1.28.0` first, then
`v2.12.0`.

Commit or stash first, as for any `update`.

## What 3.0 no longer carries

These carried a 1.x layout into 2.0. A project that ran the 2.12 `update` has
already been through every one of them.

| Dropped | What it did |
|---|---|
| Migrations `2.0.0-schema`, `2.0.0-doctor-rule`, `2.0.0-sessions`, `2.0.0-base-agents` | wrote `aiDir` and stripped per-file bookkeeping from `.myspec.json`; renamed `.claude/rules/ai-setup-audit.md` to `doctor.md`; moved live logs out of `{aiDir}/memory/sessions/active/`; offered to delete the user-scope `worker-base` / `reviewer-base` agents |
| `renamedFrom: "memory-index.md"` on `anti-patterns.md` | moved `{aiDir}/memory-index.md` to `{aiDir}/anti-patterns.md` |
| The five `removed` entries `since: "2.0.0"` | deleted `guard-git-branch.sh` (and unwired it), `{aiDir}/memory-system.md` and three unread templates |
| Doctor findings `myspec-schema-stale`, `doctor-rule-unrenamed`, `sessions-unmigrated` | reported a project the 2.0 migrations had not reached yet |
| Skill stubs `features-status-audit`, `worktree-cleanup`, `docs-sanitize` | named the 2.0 replacements; due for removal one minor after 2.0 |

If you still call one of the old skill names, switch to `/myspec:feature-status-audit`
or `/myspec:worktree-clean`. `docs-sanitize` has no successor: its jobs are
`/myspec:doctor` surface C and `/myspec:session-clean`.

## Pending in the 3.0 stack

Not merged yet; each PR or issue carries the details.

| | Change | What you may have to do |
|---|---|---|
| #255 | Container checks are declared: a `verification.json` check that execs into a container needs `runIn` and a `containers` entry | Add `runIn`. The doctor's `verification-exec-no-runin` warning names each check |
| #256 | Worktree provisioning writes `.claude/state/provision.json` and the Stop hook compares that record instead of scanning for linked dependency directories; `lib/dependency-map.sh` is removed | Re-provision worktrees made before the change. The doctor reports `link-unrecorded` and `provision-stale` |
| #257 | The Stop hook moves into `lib/stop-gate/`, with a 300 s budget for the whole stop; a missing settings reader blocks the stop instead of guessing | Run `update` before your next stop |
| #150 | The `code-review` skill is removed in favour of Claude Code's built-in `/code-review` | Not decided yet: what happens to `.claude/rules/code-review.md` and the `codeReview` block |
| #143 | Codex support and the `plugins/myspec/` mirror are dropped | Codex users stay on 2.x |

The import of 2.x session state (the `/tmp` write ledger and the implement and
isolation markers) stays for one release after #254 and #257, so a session
running across the upgrade keeps its record.
