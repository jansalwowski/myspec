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
| R6 | While `/myspec:feature-implement` orchestrates (its last `implement` event a start under 8 h old), check failures warn and don't block. The state is the session's own, read once, and covers every checkout the session armed, the task worktrees its subagents edit included; another session's run does not. Its final verification still gates. | #95 |
| R7 | A check that hits the 120 s cap is reported as timed out, not failed. The cap bounds the hook's wait and kills the check's process group. Remote work gets the check's `cleanup`. The cap is never raised. | #115, #147 |
| R8 | A dependency directory symlinked into a checkout with different lockfiles, or one that loads that checkout's source, blocks before any check runs. Loading that checkout's source includes a workspace link: a directory symlink in the tree's top two levels, or two levels into a nested link directory such as pnpm's hidden hoist (`.pnpm/node_modules`), that resolves out of the tree. Every such link is resolved physically, whatever its text, and a tree the scan cannot list (a `find` that cannot run) counts as loading, while an unreadable directory inside the tree does not. The built-in directories include the Composer bin plugin's `vendor-bin/*/vendor`. | #94, #229, #222 |
| R8a | In a linked worktree, or a submodule checked out inside one, a check whose command runs a container exec without `-w`/`--workdir` in its exec options is refused as unverifiable instead of run. The exec forms are data in the hook (`CONTAINER_EXEC_FORMS`): `docker exec`, `docker container exec`, `docker compose exec`, `docker-compose exec`, `podman exec`, `podman container exec`, `podman compose exec`, `podman-compose exec`. Such a check runs in the container's mount of the checkout the container or compose project was started from, so its result describes another tree. A `-w` is trusted, not verified: the gate cannot see what the container mounts at that path, so a `-w` naming the main checkout's mount still passes on the main tree. A check with `runIn` (R12) is exempt when its command uses the workdir the gate computes from the mount mapping: it passes `-w`/`--workdir` or names `MYSPEC_CHECK_WORKDIR`. A `runIn` check whose exec does neither is still refused, with "pass `-w \"$MYSPEC_CHECK_WORKDIR\"`". Short-flag clusters are parsed (`-Tw <dir>` sets the workdir; `-ew` is `-e w`). The refusal blocks, never warns through attribution, and does not apply in the main checkout or its own submodules. | #220 |
| R9 | Memory and setup conformance errors block only when they are errors. Warnings, such as a duplicate ID on stale branches only, don't block. | #124 |
| R10 | One block per stop: the continuation after a block (`stop_hook_active`) is approved. | 4eb8ccb |
| R11 | A check with `paths` runs only when a file this session wrote in that checkout (`$MYSPEC_SESSION_FILES`, code or not) matches one of its globs; without `paths` it always runs. A required check skipped this way is named in the stop message, an approve included (a `systemMessage`), so the loosening is never silent. A `paths` that is not a non-empty list of usable globs is ignored, the check runs, and the message names it. The ledger misses writes it cannot see (`git revert` or `checkout`, `rm`, a code generator, a variable path), so a path git reports changed in that checkout also runs the check when it matches: uncommitted or untracked (`git status`), or changed against `$MYSPEC_BASE_REF` (R5). On a feature branch that includes the branch's earlier commits, so a check skips only when its globs match nothing the branch or the working tree changed. Glob semantics: see Per-check settings. | #232 |
| R12 | A check with `runIn` names a container in the top-level `containers` map (`{mountSource, mountTarget}`). The gate exports `MYSPEC_CHECK_WORKDIR`, where this checkout's `mountSource` sits inside the container, and does not apply R8a's refusal to it when the command passes `-w`/`--workdir` or uses `MYSPEC_CHECK_WORKDIR`. When the checkout's `mountSource` is not under the main checkout's (a worktree outside the mounted directory), the check is refused with "this worktree is not visible inside the container" and never run. A `runIn` naming an undefined container, or a container without a repo-relative `mountSource` and an absolute `mountTarget`, refuses the check with its reason. Refusals block like R8a's. | #221 |

## Session writes (R1–R4)

Session state is one append-only file per session, `.claude/state/sessions/<session_id>.jsonl` in the main checkout, beside the session's live log. `lib/session-event.sh` is its only writer and reader. Each line is one JSON event with `at` (epoch seconds): `write`, `verified`, `isolation` (`set-isolation.sh`) and `implement` (R6). Appends are single short `O_APPEND` writes, so concurrent subagents' lines don't interleave, and a reader skips a line that does not parse. The file is in the checkout, not `/tmp`, so `TMPDIR` does not matter: the hooks of one session agree on it whatever their environment.

`mark-code-changed.sh` appends one `write` event per written file: `{"t":"write","root":<checkout root>,"rel":<repo-relative path>,"kind":"code|file"}`. The root is the physical toplevel of the checkout holding the file, so a linked worktree and another repository each get their own events. The event goes to the state file of the main checkout of the file's repository (a submodule's goes to its superproject's), and only when that checkout has a `.myspec.json` or a `.claude/verification.json`. `verify-before-stop.sh` appends `{"t":"verified","root":<root>}` for each checkout after it runs the checks. A checkout is armed when a `code` write for its root comes after its last `verified` event, and every armed checkout that shares the cwd's git common dir is verified (R3a). An armed checkout nested inside the cwd's tree that is not a checkout of this repository, such as a submodule, is verified through the cwd's checkout, and the files written in it count as the session's there. Each check gets `$MYSPEC_SESSION_FILES`: the files this session wrote in that checkout, one repo-relative path per line, so a per-file linter can scope itself to them.

For a Write or Edit, the written file is the tool's `file_path`. For Bash, only the targets of the write are recorded: a redirect target, the operands of `tee`, `sed -i` and `perl -i` (`-i` anywhere among the options, the command called by any path), every operand of `mv`, the destination of `cp`, `rsync` and `install`, and the files `patch` edits and writes (`-o`). Before, every code path anywhere in a command counted once any segment wrote. A quoted literal path is read through the scanner's `keep` mode. A variable path stays invisible, and so do `git apply` and a script that writes from inside a heredoc. Relative targets resolve against the payload `cwd`, moved by a literal `cd` earlier in the command and restored when a subshell ends.

Every written file is recorded, code or not, because the ledger is also the attribution list: a `tsconfig.json` or `package.json` this session edited must count as its own.

What counts as code is `CODE_EXT` plus `hooks.markCodeChanged.extraCodeExtensions`, and a path matching a `hooks.markCodeChanged.ignorePaths` glob is recorded as `file` even when its extension is code, so generated output never arms the gate by itself (#231, `docs/project-settings-design.md`). Both are read through `lib/myspec-config.sh` from the checkout holding the written file, not the cwd's, falling back to its primary checkout when it has no `.myspec.json`. The globs are repo-relative and follow the `paths` rules under Per-check settings: one compiler, `lib/glob-regex.sh`, serves `ignorePaths`, `checks[].paths` and `isolation.provision.clean`. A default extension can't be removed; ignoring the paths that hold it does that. A malformed value falls back to the default and is named on stderr.

Subagents share their parent's `session_id`; their tool events add `agent_id` and `agent_type`, and the main session's carry neither (#225). The state file stays keyed by `session_id`, so a subagent's write arms the parent's gate and counts as the session's file, and a subagent reads its parent's isolation decision. A subagent's `write` event gains `"agent":<agent_id>`. In the session log a subagent's path is tagged `` - `path` (subagent <agent_id>, <agent_type>) ``, which is how session-complete keeps the controller's own edits apart from delegated ones.

The ledger outlives each run: the `write` events are the list of files the session wrote, which attribution reads on every run. Before the state file it was `/tmp/.myspec-session-writes-<session_id>`, one tab-separated line per write. For one minor release, the one that introduces the state file, the first read or write of a session whose state file does not exist yet imports that file once and renames it `.imported`, so a session running across the upgrade keeps its ledger; the next minor drops the import. The empty `/tmp/.myspec-code-changed-<session_id>` marker before it is no longer read.

## Attribution (R4)

It applies per verified checkout, when its checks fail and the session is not in a feature-implement run. Let T be the files this session wrote in that checkout. Let F be the uncommitted and untracked files not in T, excluding `.claude/state/`.

1. F is empty: every uncommitted change is this session's. Block.
2. A failing check's output names a file in T: block. T is matched by basename, which errs toward blocking.
3. Every failing check names a file in F and none in T, and no check timed out: approve, and put the failures in a `systemMessage` for the user. F is matched by its full repo-relative path, which errs toward blocking.
4. Otherwise: block. The reason lists F and tells the agent not to edit those files to make a check pass.

**Known limits.** A Bash side effect (an install, code generation, a formatter), or a Bash write to a variable path, is not in T. When it lands in F, a failure that names only that file warns instead of blocking (rule 3). The block message in rule 4 says so. A change by this session that breaks a file another session has open also warns (rule 3): the failure is real, but the other session's gate owns it. Several sessions in one checkout can't be separated exactly. A worktree per session is the fix, and the warning says so.

**Not covered.** The memory and setup conformance gates are still armed by uncommitted changes under the memory tree or `.claude/`, not by this session's writes. Many of those writes come from lib scripts through Bash, which the ledger can't see.

## Per-check settings (R11, R12)

The gate reads `checks` and `containers` through `lib/myspec-config.sh`, the one settings reader (`docs/project-settings-design.md`), from the checkout whose `.claude/verification.json` is in use. A hook installed without the reader reads `checks` from the file as before and refuses every `runIn` check, because it cannot read `containers`. Order per required check: `paths` first (a skipped check is never refused), then `runIn` or the R8a refusal, then the run.

**Globs (`paths`).** Each glob is matched against each session file as a repo-relative path. These are the semantics doctor validates (#233):

- A glob matches the whole path from the repository root. `*.php` matches only a file at the root; `**/*.php` matches one at any depth.
- `*` matches any run of characters within one path segment, and `?` matches one character other than `/`.
- `**` as a whole segment matches zero or more segments: `api/**` is everything under `api/`, and `a/**/b.ts` matches `a/b.ts` and `a/x/y/b.ts`. `**` inside a segment (`a**b`) is a plain `*`.
- A trailing `/` means everything under it (`api/` is `api/**`), and a leading `./` is dropped.
- Every other character is literal, including `[`, `{` and `\`. There are no classes and no braces: list two globs instead of `{api,worker}/**`.
- An empty glob, an absolute one, or one with a `..` segment is unusable.

The set matched is every file the session wrote in the checkout, not only those since the last run. A check that failed before still runs after the session moves on to other directories.

**Workdir (`runIn`).** Let M be the main checkout (`checkout_facts` in `lib/hook-core.sh`; for a submodule, its superproject's main checkout plus the submodule's path) and C this checkout. A checkout whose repository has no main checkout git can name (a bare repository's worktree) refuses a `runIn` check. `MYSPEC_CHECK_WORKDIR` is `mountTarget` plus the path of `C/mountSource` under `M/mountSource`. With `mountSource` `.` that is `mountTarget` in the main checkout and `mountTarget/.claude/worktrees/<name>` in a worktree under the default `isolation.worktreeRoot`. With `mountSource` `api`, a worktree's `api/` is not under the main checkout's `api/`, so only the main checkout is visible. A polyglot pair:

```json
{
  "containers": { "api": { "mountSource": ".", "mountTarget": "/srv/app" } },
  "checks": [
    { "name": "API tests", "command": "docker compose -p myapp exec -w \"$MYSPEC_CHECK_WORKDIR/api\" api composer test", "runIn": "api", "paths": ["api/**"], "required": true },
    { "name": "Web typecheck", "command": "npx tsc --noEmit -p web", "paths": ["web/**"], "required": true }
  ]
}
```

The PHP suite runs in the container and the TypeScript check on the host, each only when the session wrote under its directory. `-p myapp` pins the compose project to the one started from the main checkout: without it compose names the project after the directory it runs in, and the gate runs the command from the worktree root, so from `.claude/worktrees/<name>` it looks for a project `<name>` and finds no running service. A top-level `name:` in the compose file pins it too, and so does exec on the container by its name (`<runtime> exec <container>`). The command is the project's, so `podman exec`, `nerdctl exec` or `kubectl exec` work the same way.

## Verification

- `lib/tests/hook-core.test.sh`: the primitives every hook shares: payload parsing with missing fields, physical paths, and which checkout is the main one in a plain repo, a linked worktree, a bare repository with worktrees, `--separate-git-dir`, a submodule inside a worktree, a symlinked root and paths with spaces.
- `lib/tests/session-event.test.sh`: the state file: append and read, a truncated last line, 20 concurrent writers, where the file lives, arming and attribution queries, TTL expiry of the isolation decision and the implement state, no lookup across sessions, and the one-time import of the `/tmp` ledger.
- `hooks/tests/mark-code-changed.test.sh`: write targets, `/dev/null` and descriptor redirects, `cd` and subshell scope, foreign roots, non-code writes as `file`, and `implement` events recorded from the command.
- `hooks/tests/verify-before-stop-attribution.test.sh`: arming per root, a worktree edited from the main checkout, the ledger outliving a run, the `/tmp` ledger import, a different `TMPDIR` per hook, and each attribution rule, including #198's repro.
- `hooks/tests/verify-before-stop-implement-marker.test.sh`: R6: a fresh, stale, unreadable, future-dated and stopped run, a start recorded by `mark-code-changed.sh`, a task worktree, and another session's run.
- `hooks/tests/verify-before-stop-regression.test.sh`: which checkouts the ledger verifies (#201).
- `hooks/tests/verify-before-stop.test.sh`: linked dependency directories (R8), including workspace links, `vendor-bin/*/vendor` and a `find` without `-lname`, and container execs in a linked worktree and its submodules (R8a), including each exec form and short-flag clusters.
- `hooks/tests/verify-before-stop-check-scope.test.sh`: `paths` (R11) matching, skipping and the message, each glob rule, unusable settings, and changes the ledger cannot see (`rm`, an untracked file, a commit against the base); `runIn` (R12) in the main checkout, a nested worktree and one outside `mountSource`, a subdirectory mount, undefined and malformed containers, the interaction with R8a (an exec without `-w` or the workdir is refused), and the documented example.
