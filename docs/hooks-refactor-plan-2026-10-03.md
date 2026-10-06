# Hooks: stop the churn — refactor plan

Status: implemented. Proposed 2026-10-03; steps 1-3 and 8 shipped in 2.11.0 (#251-#254), steps 4-7 in 3.0.0 (#255-#257; the step 7 deletions in #259, #260, #273). Kept as the record of why the hooks are shaped this way. Written from the issue history (48 issues, #94 to #249), the commit history since 2026-09-27, and a read of the four hooks at 2.10.0. Companion to `stop-gate.md` (requirements) and `project-settings-design.md` (settings). Nothing here changes a requirement; it changes where each one is enforced.

## Diagnosis

Between 2026-09-27 and 2026-10-02 the hooks went from 1511 to 3577 lines and their tests from 453 to 2991. The same functions were rewritten three to five times in six days: the linked-dependency guard (`tree_loads_checkout`, five commits), the capped runner (`run_capped`, three), the branch guard (`branch_verdict`, five), the Bash write scanner (`bash_write_targets`, three). Every rewrite widened or narrowed one rule, and PR review or a downstream doctor run found the case it left (#111, #151, #203, #236, #243, #245). The maintainer's own words on #198: "the fourth time the gate has blocked on a failure the session didn't cause".

Three causes, in order of weight:

1. **The gate owns stack knowledge it cannot complete.** "Which tree does this check describe?" is answered inside `verify-before-stop.sh` one dependency mechanism at a time: symlinked `node_modules` (#94), pnpm workspace links (#229), Composer `$baseDir` and `vendor-bin` (#222), editable `.venv` installs, a Compose bind mount of the main checkout (#219, #220, #221), a shared `tsbuildinfo` (#193), a tracked `.gitkeep` inside a linked directory (#239). Each is a new 30 to 100 line special case, and the next stack (Go module cache, Cargo `target/`, Gradle caches) is not in the list. The lockfile map is copied byte for byte into `worktree-provision.sh`, with a test that enforces the copy.
2. **Shell commands and the filesystem are parsed with regexes.** `mark-code-changed.sh` guesses writes from command text; `guard-worktree-context.sh` matches `^git checkout` after a prefix strip. Every bypass or false block is one more prefix, option or redirect form (#126, #145, #164, #176, #179, #223, #249). The scanner cannot see a variable path, a heredoc script, `git apply` or a code generator, so R11 already falls back to `git status` for what the ledger misses.
3. **Shared state agrees by convention only.** Four hooks and three libs each resolve the payload cwd, the main checkout and the physical root on their own (six resolvers, three glob compilers, four copies of the TTL constants). The ledger is written with four fields and read with three. The `/tmp` ledger path ignores `TMPDIR`. The isolation marker, the implement marker and the ledger are three files with three keys, so a fix in one (agent_id, #225) does not reach the others (the implement marker is still looked up per checkout).

## What to keep

The requirements in `stop-gate.md` are right and hard-won. Keep every one of R1 to R12, the settings design (framework owns scripts, project owns data), the per-check `paths`, `runIn`, `cleanup` and `diffCommand` contract, the attribution rules, the silent PreToolUse pass, and the ShellCheck and test gates. Keep bash: `project-settings-design.md` makes jq the hooks' only dependency, and Go, PHP and Python containers often lack node.

## Steps

Each step is one PR, lands independently, and comes with the tests named. Order matters only where stated.

### 1. Defects found by reading, fixed first

Reproduced at 2.10.0 with scratch repos. All are regressions of the same two shapes (SIGPIPE under `pipefail`, and a logical/physical or per-root mismatch), and the lint rule in this step is what stops the shape from returning.

| Defect | Effect | Fix |
|---|---|---|
| `mark-code-changed.sh` `printf \| tr \| head -c 120` (#249) | A Bash command over ~26 KiB (a heredoc writing a source file) exits the hook 141; the ledger is never written, so the gate never arms. Silent false green. | Bash substring. |
| `verify-before-stop.sh` `git status \| grep -q .` (twice) | A large status under the memory tree or `.claude/` skips the memory and setup conformance gates. | `[ -n "$(git status …)" ]`. |
| `require-isolation-decision.sh` logical `file_path` vs physical `REPO_ROOT` | An edit through a symlinked path is approved as "outside the repo", with no decision and in worktree mode. | Resolve the file's directory physically before the prefix strip. |
| Implement marker looked up per verified root | During `feature-implement`, a failure in a task worktree blocks while the same failure in main warns (R6 broken for the roots that matter). | Look the marker up once per session, apply to every armed root. |
| `find … \|\| return 0` in the linked-dependency scan | One unreadable directory in a correctly linked `node_modules` blocks every stop. | Use the output `find` produced; ignore its exit status. |
| Three glob compilers disagree | `src/**.ts` matches `src/x/y.ts` in two of them; `ignorePaths: ["gen/"]` ignores nothing. | One `lib/glob-regex.sh`, one test file, the semantics `stop-gate.md` already documents. |

Plus: a `scripts/lint-sh.sh` rule that flags a `head`/`grep -q` consumer in a pipeline whose status is consumed, in any script under `pipefail`. `validate-frontmatter.sh` hit this class in #33, `mark-code-changed.sh` in #249; the rule makes the third occurrence a lint failure instead of an issue.

### 2. `lib/hook-core.sh`: one copy of each primitive

Sourced by every hook and by `worktree-provision.sh`, `set-isolation.sh`, `task-worktree.sh`:

- `payload_field …`: one jq call per hook that extracts every field it needs (`cwd`, `session_id`, `agent_id`, `tool_input`, `stop_hook_active`).
- `physical_path`.
- `checkout_facts <path>`: one `git rev-parse --show-toplevel --git-dir --git-common-dir --show-superproject-working-tree` call, returning root, main checkout, `is_linked`, `is_submodule`. Replaces the five resolvers that assume the common dir is named `.git` (breaks today on `--separate-git-dir` and bare-plus-worktrees layouts).
- Marker TTLs as constants.
- The glob compiler from step 1.

Tests: `lib/tests/hook-core.test.sh` over a plain repo, a linked worktree, a submodule inside a worktree, a bare repo with worktrees, `--separate-git-dir`, a symlinked root, and paths with spaces. Each hook's own suite shrinks by the cases the core now covers. No behaviour change intended; where the resolvers disagreed today, the test names which one wins and why.

### 3. One session-state file

Replace the `/tmp` ledger, the legacy marker, `.claude/state/isolation/<sid>.json` and `.claude/state/implement-in-progress.json` with one append-only `.claude/state/sessions/<sid>.jsonl` in the main checkout, written and read through `lib/session-event.sh`:

```
{"t":"write","root":"…","rel":"src/a.ts","kind":"code","agent":"…"}
{"t":"verified","root":"…"}
{"t":"isolation","mode":"worktree","path":"…"}
{"t":"implement","state":"start"}
```

One key (session id, with `agent` as a field), one location (not `/tmp`, so it survives `TMPDIR` differences and is visible to doctor and `session-clean`), one parser, one TTL. Skills call `session-event.sh implement start` instead of writing JSON by hand. `.claude/state/` is already the gitignored per-checkout contract in AGENTS.md; this step narrows it to one file per session plus the existing `.md` log. Migration: read the old files for one minor release; `update` deletes them after. Tests move from the attribution and implement-marker suites onto the lib.

### 4. Linked dependencies: provision records, the gate compares

Today `verify-before-stop.sh:242-512` re-derives at every stop what `worktree-provision.sh` knew when it made the link. Instead, provision writes what it did to `.claude/state/provision.json` in the worktree. Not session state: a worktree outlives the session that provisioned it, so the record has no TTL and belongs to the tree, where every later session's stop and `doctor` can read it.

```
{"link":"node_modules","source":"<main>/node_modules","lockfiles":{"pnpm-lock.yaml":"<sha256>"}}
```

The gate then does two things with no stack knowledge: refuse a stop when a recorded lockfile's hash differs from the file now on either side (the worktree's own copy, which a branch may edit after provisioning, or the main checkout's, which the link resolves into), and refuse when a recorded link's physical target is not the recorded one. Lockfile patterns that matched nothing at provision time are recorded as absent, so a lockfile that appears later on either side also refuses. What this gives up: a linked tree that starts loading the main checkout's source only after provisioning (an editable reinstall, a `dump-autoload`) is caught at the next provision run or by `doctor`, not at stop; the old scan caught it at stop and that is the trade for deleting the scan. A directory that provision did not link is not the gate's business; a hand-made link is a `doctor` finding ("dependency directory links out of the tree, not recorded by provision"). The `tree_loads_checkout` scan, `DEP_DIRS`, the duplicated lockfile map and its drift test all go. R8 is reworded: "a linked dependency directory whose lockfiles changed since provisioning, or whose link no longer points into the recorded source, blocks". #239 (a tracked placeholder blocks the link) becomes a provision-time error with a message, which is where the user can act on it.

This is a behaviour change (a hand-made symlink in a tree never provisioned is no longer caught at stop). Label the PR as such; the `work-isolation.md` procedure already routes worktree creation through provision.

### 5. Containers: declare, do not parse

`verify-before-stop.sh:782-888` parses `docker`/`podman` exec forms and short-flag clusters to decide whether a check targets the right tree. Move that parser to `setup-doctor`, where it produces one finding: "check `<name>` runs a container exec without `runIn`; in a linked worktree it will verify the main checkout". In the hook, a check with `runIn` is trusted (R12 computes the workdir), a check without `runIn` that is a container exec is refused in a linked worktree by matching the declared `CONTAINER_EXEC_FORMS` as whole words with program options allowed between them (`docker compose -f compose.yml exec …`, `docker --context x exec …` still match, which keeps #220 closed); only the exec-option inference (`-w`, short-flag clusters) goes, since `runIn` now says where the check runs. Add a per-check `cwd` (repo-relative) to the schema so a monorepo package check does not need a `cd` in its command. R8a shrinks to three sentences. `guard-worktree-context.sh`'s `HEAVY_PATTERNS` move to schema defaults for `isolation.blockInMain`, so a Gradle or Maven project adds its build command as data.

### 6. Split what remains, add a gate-wide budget

After steps 1 to 5, `verify-before-stop.sh` is the arming decision, the capped runner, attribution, the `paths` and `runIn` verdicts and the output. Split into `lib/stop-gate/{arm,run,attribute,report}.sh` behind a shim of about 100 lines, so each part has function tests instead of 184 s of end-to-end suites. Add one gate-wide time budget covering all roots and all checks, lowered and never raised: today the worst case is checks × roots × 150 s and the harness's own hook timeout decides the outcome.

### 7. Delete

- Legacy `/tmp/.myspec-code-changed-<sid>` support and the `ATTRIBUTE=0` paths (nothing writes the marker since f8675af).
- The "newest marker by mtime" fallbacks in `guard-worktree-context.sh` and `require-isolation-decision.sh`: since #225 established that subagents carry the parent's `session_id`, that branch only leaks between sessions.
- The no-settings-reader fallbacks; the reader is shipped with the hooks.
- The guessed payload fields (`.workdir`, `.workspace.cwd`, `.session.cwd`).
- The 3 KB `notes` blob in `templates/verification.json`; it belongs in docs the template links to.
- `plugins/myspec/` (#143), separately: 163 of 238 recent commits touched the mirror, and #218 exists only because of it.

### 8. Hook commands are installed absolute

#216 and #217 closed the detection side: doctor flags a bare `.claude/hooks/x.sh` and `update` rewrites it. The installer still writes the bare form, so every new project starts with a gate that disappears after the first `cd` into a subdirectory (a Stop hook failure is non-blocking, so nothing says so). `init` and `update` write `"$CLAUDE_PROJECT_DIR"/.claude/hooks/x.sh` from the start, doctor's finding becomes an error, and the template test asserts no bare form ships. #218 (the Codex `hooks.json`) goes with #143.

## Guard-rails for every step

- A new test must fail with the fix reverted (AGENTS.md "Quality gates"); the PR body shows the failing line.
- `stop-gate.md` is edited in the same PR when an R's wording changes, and no new R is added without an issue number.
- No new `MYSPEC_*` variable or settings key without a schema entry and a doctor line (`project-settings-design.md` principle 7).
- No stack name in a hook (AGENTS.md "Stack-agnostic content"). The `git grep` from that section runs before each PR.
- Any `| head` / `| grep -q` under `pipefail` is a lint failure (step 1).

## Expected outcome

About 700 lines leave `verify-before-stop.sh` (steps 4, 5, 7), roughly 400 more leave the four hooks together through `hook-core.sh` (step 2), and the issue classes behind #94, #193, #211, #219, #220, #222, #229, #239 (wrong tree), #145, #179, #249 (command parsing), #146, #225 (session identity) and #216 to #218 (cwd-relative commands, steps 7 and 8) stop having a place to recur.
