---
title: "Work Isolation Procedure"
purpose: "How to ask, record, and carry out the develop-vs-worktree decision once an isolation hook blocks"
updated: 2026-10-10
---

# Work Isolation Procedure (develop vs worktree)

`.claude/rules/work-isolation.md` is the always-loaded contract; this file is the procedure the isolation hooks' block messages point at. Read it when a block fires.

Where code gets written is the user's call, not the agent's. `require-isolation-decision.sh` (PreToolUse `Write|Edit`) blocks the first source edit in the main checkout until the answer is recorded; `guard-worktree-context.sh` (PreToolUse `Bash`) blocks branch mutations on the main checkout always, tree-specific commands there once a session has chosen a worktree, and a Bash write the Write tool would not be allowed to make.

Edits under `${aiDir}/`, `.claude/`, `docs/` and the root agent files do not trigger the **question** on a feature branch — doc work there is not gated on an isolation decision — unless `.myspec.json` sets `isolation.gateDocs: true`, which asks it for them too. On a protected HEAD they are asked like source, with no setting: a detached HEAD, the default branch, or a branch matching an `isolation.protectedBranches` glob (add the integration and release branches there, e.g. `["develop", "release/*"]`). A doc written there lands on the integration branch. They are *not* exempt from an answer already given: once a session is in worktree mode, a doc edit aimed at the main checkout is blocked like any other. Two paths are pinned to the main checkout whatever the answer: `.claude/state/` (live session logs, session-state files, the ID registry) and `${aiDir}/memory/sessions/` (the session archive); `isolation.gateDocs` never gates them.

A file written through `Bash` is judged as a `Write` of that file when the command names it, `bash -c` and `eval` payloads included: a redirect or heredoc (`>`, `>>`, `>|`), `tee`, `sed -i`, `perl -i`, `mv`, `cp`, `rsync`, `install`, `ln`, `rm`, `touch`, `truncate`, `dd of=`, `patch`. In worktree mode, `MYSPEC_ALLOW_MAIN_CHECKOUT=1` lifts this block as it does the command block below. A write the command does not name — an interpreter's (`python -c`, `node -e`), a variable path — is recorded by `mark-code-changed.sh` after it lands, never blocked. Edit files in the main checkout with `Write`/`Edit` or a named Bash target, never an interpreter one-liner.

## At the start

On the block, call `AskUserQuestion` with one question — `header: "Isolation"`, options `develop` and `Worktree` — then record it:

```
set-isolation.sh <session_id> develop|worktree
```

The block message prints the exact command with the path resolved: `set-isolation.sh`, like every helper named in this file, runs from the myspec plugin's `lib/` (`${CLAUDE_PLUGIN_ROOT}/lib/` inside a skill), never from `.claude/`, and the hook's messages are where the resolved path comes from. The session id is embedded in that message, and that is its only source. Never take one from `.claude/state/sessions/` filenames: every session in the checkout has a file there, and nothing shows which is yours. `set-isolation.sh` refuses to change a live decision already recorded under an id; if the user really changed the answer, `--reset` it first. Mark one option `(Recommended)` from the heuristic below; presenting them as equals wastes the prompt.

| Recommend `develop` | Recommend `Worktree` |
|---|---|
| Single-file fix, config tweak, copy change | Multi-file or cross-layer change |
| The user said they want to see it running now | Dependency bumps, lockfile churn |
| Debugging where the next step depends on live output | Anything touching the build, SSR, or framework config |
| Small test or fixture edit | Needs a full build or a long e2e run |
| | Risky refactor, or the user is likely to want it reverted wholesale |

Do not ask about a PR here. That question belongs at the end, when the size of the change is known.

**Subagents cannot prompt.** Decide before dispatching. A subagent that hits the gate must stop and report back, not ask. A subagent shares its parent's session id, so it follows the parent's decision. No session inherits another session's answer: one without a decision is asked, and a subagent without one stops and reports. `isolation: "worktree"` subagents edit inside their worktree, which needs no decision, but an edit from a worktree back into the main checkout is gated like any other.

## develop mode

Edits land in the user's checkout so they can test immediately. **Do not commit** unless asked: end-of-work promotion moves an uncommitted working-tree diff, and commits on the base branch cannot be promoted without rewriting the user's local branch — `promote-to-worktree.sh` refuses rather than doing that silently.

## worktree mode

```
git worktree add -b <type>/<slug> "$(git rev-parse --show-toplevel)/.claude/worktrees/<slug>" origin/<default-branch>
worktree-provision.sh "$(git rev-parse --show-toplevel)/.claude/worktrees/<slug>" --base origin/<default-branch>
set-isolation.sh <session_id> worktree --worktree-path <abs worktree path>
```

The worktree block message prints both commands with their paths resolved (a skill reads them from `_shared/worktree-provisioning.md`).

Provisioning links each `isolation.provision.symlink` entry (default `node_modules`) except one pinned by a lockfile the branch changed or that differs from the main checkout's, which needs a real install instead; it copies the lint cache and keeps both out of git; `.myspec.json` `isolation.provision` extends the lists. Never symlink a build output directory. Recipe and rationale: `_shared/worktree-provisioning.md` in the plugin.

Absolute paths and `git -C <worktree>` for every git call. Write files with the Write tool. Provisioning records what it linked; the Stop hook blocks when a recorded lockfile changed since, or a recorded link moved, and says to rerun provision. Link dependency directories only through provision: a hand-made link is not compared, and doctor reports it.

`guard-worktree-context.sh` enforces the split for Bash: while this session is in worktree mode, builds (`build:<target>` scripts included), installs, e2e runs, `lint:fix`, `docker compose exec`, `git push` and `git worktree prune` are blocked in the main checkout (the list is the setting `isolation.blockInMain`: a project's patterns extend its default, and `isolation.ignoreBlockInMain` drops a default one). Lint, dev servers, unit tests and read-only git (`git worktree prune --dry-run` included) stay allowed. When the main checkout genuinely is the right place — refreshing the symlinked `node_modules`, say — prefix the command with `MYSPEC_ALLOW_MAIN_CHECKOUT=1`.

A PR is always opened when the work is done — the user cannot inspect a worktree in the IDE.

## At the end (develop mode only)

Ask whether to open a PR. If yes, run the plugin's `promote-to-worktree.sh` — `/myspec:feature-complete` does, and the isolation hook's block message prints its resolved path:

```
promote-to-worktree.sh --branch <type>/<slug> --title "<conventional commit subject>" \
  --only <path> [--only <path>]... [--body-file <path>] [--trailer "<Key: value>"]... [--session-url <url>]
```

It copies the diff into a fresh worktree, commits, provisions, pushes, and opens the PR against the default branch (`--base` overrides). The main checkout never changes branch and is restored once the push succeeds — the diff lives on the branch, and a copy left behind only arms a conflict at the next pull. **Always pass `--only`**: the main checkout is shared, and an unscoped promotion bundles concurrent agents' and the user's own WIP into one PR. `--keep-tree` keeps the diff for local testing; you then own clearing it before pulling.

## Resetting

```
set-isolation.sh --show                 # current decisions
set-isolation.sh --reset <session_id>   # force a re-ask
```

The isolation hook's ask message prints both with the path resolved.

Decisions expire after 8h.
