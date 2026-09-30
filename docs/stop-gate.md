# Stop gate: requirements

The stop gate is two hooks. `mark-code-changed.sh` (PostToolUse) records what a session writes. `verify-before-stop.sh` (Stop) runs the checks in `.claude/verification.json` when the session changed code and blocks the stop on a failure. This file collects what the gate must do, from the issues that shaped it, so the next change is checked against all of them rather than the one in front of it. Design notes for single parts: `verify-check-escapes.md` (time cap), README "Isolation" (linked dependency directories).

## Requirements

| # | Requirement | Source |
|---|---|---|
| R1 | Run the checks only when this session wrote a code file in this checkout since the last run. Reading, grepping or running a file is not a write, and neither is a redirect to `/dev/null` or to a file descriptor. | #145, #179 |
| R2 | A write in another repository or outside the checkout (a scratchpad, `/tmp`) does not arm this checkout's gate. | #145, #152 §3 |
| R3 | Code extensions cover the common stacks as data, GraphQL included. | #152 §3, 67f0814 |
| R3a | Verify each checkout of this repository the session wrote code in, not the cwd's. A session whose cwd is the main checkout can edit a linked worktree, and verifying the untouched main checkout is a false green. | #201 |
| R4 | Block only on a failure this session can be tied to. When the tree has uncommitted changes this session did not write and a failing check names only those files, warn instead of blocking. When that can't be settled, block, and say which files are this session's and which aren't, so the agent never "fixes" another session's work. | #198 |
| R5 | A check that is red on the default branch can be scoped to what the branch changed (`diffCommand`, `$MYSPEC_BASE_REF`). | #12 |
| R6 | While `/myspec:feature-implement` orchestrates (marker under 8 h old), check failures warn and don't block. Its final verification still gates. | #95 |
| R7 | A check that hits the 120 s cap is reported as timed out, not failed. The cap bounds the hook's wait and kills the check's process group. Remote work gets the check's `cleanup`. The cap is never raised. | #115, #147 |
| R8 | A dependency directory symlinked into a checkout with different lockfiles, or one that loads that checkout's source, blocks before any check runs. | #94 |
| R9 | Memory and setup conformance errors block only when they are errors. Warnings, such as a duplicate ID on stale branches only, don't block. | #124 |
| R10 | One block per stop: the continuation after a block (`stop_hook_active`) is approved. | 4eb8ccb |

## Session writes (R1–R4)

`mark-code-changed.sh` appends one line per written file to `/tmp/.myspec-session-writes-<session_id>`: `<kind>\t<checkout root>\t<repo-relative path>`. `kind` is `code` or `file`. The root is the physical toplevel of the checkout holding the file, so a linked worktree and another repository each get their own lines. `verify-before-stop.sh` appends `verified\t<root>\t-` for each checkout after it runs the checks. A checkout is armed when a `code` line for its root comes after its last `verified` line, and every armed checkout that shares the cwd's git common dir is verified (R3a).

For a Write or Edit, the written file is the tool's `file_path`. For Bash, only the targets of the write are recorded: a redirect target, the operands of `tee`, `sed -i`, `perl -i`, `mv`, the destination of `cp`, `rsync` and `install`, and the file `patch` edits. Before, every code path anywhere in a command counted once any segment wrote. Quoted and variable paths stay invisible, and so do `git apply` and a script that writes from inside a heredoc. Relative targets resolve against the payload `cwd`, moved by a literal `cd` earlier in the command and restored when a subshell ends.

Every written file is recorded, code or not, because the ledger is also the attribution list: a `tsconfig.json` or `package.json` this session edited must count as its own.

The ledger outlives each run. The empty `/tmp/.myspec-code-changed-<session_id>` marker it replaces was deleted after every run, which erased the list of files the session had written. That marker is still honoured: it arms the cwd's checkout with attribution off, and is removed after the run.

## Attribution (R4)

It applies per verified checkout, when its checks fail, its feature-implement marker is absent, and the ledger (not a legacy marker) armed the gate. Let T be the files this session wrote in that checkout. Let F be the uncommitted and untracked files not in T, excluding `.claude/state/`.

1. F is empty: every uncommitted change is this session's. Block.
2. A failing check's output names a file in T: block. T is matched by basename, which errs toward blocking.
3. Every failing check names a file in F and none in T, and no check timed out: approve, and put the failures in a `systemMessage` for the user. F is matched by its full repo-relative path, which errs toward blocking.
4. Otherwise: block. The reason lists F and tells the agent not to edit those files to make a check pass.

**Known limits.** A Bash side effect (an install, code generation, a formatter) is not in T. When it lands in F, a failure that names only that file warns instead of blocking (rule 3). The block message in rule 4 says so. A change by this session that breaks a file another session has open also warns (rule 3): the failure is real, but the other session's gate owns it. Several sessions in one checkout can't be separated exactly. A worktree per session is the fix, and the warning says so.

**Not covered.** The memory and setup conformance gates are still armed by uncommitted changes under the memory tree or `.claude/`, not by this session's writes. Many of those writes come from lib scripts through Bash, which the ledger can't see.

## Verification

- `hooks/tests/mark-code-changed.test.sh`: write targets, `/dev/null` and descriptor redirects, `cd` and subshell scope, foreign roots, non-code writes as `file`.
- `hooks/tests/verify-before-stop-attribution.test.sh`: arming per root, a worktree edited from the main checkout, the ledger outliving a run, the legacy marker, and each attribution rule, including #198's repro.
- `hooks/tests/verify-before-stop-regression.test.sh`: which checkouts the ledger verifies (#201).
