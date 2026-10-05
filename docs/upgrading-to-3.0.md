# Upgrading to myspec 3.0

`/myspec:update` does the mechanical work. This page covers the rest: the
changes that live in files myspec does not own, and the behaviour changes that
have no file to grep at all.

Read it after the update run, with the summary it printed still on screen. The
breaking changes are tracked in the
[v3.0.0 milestone](https://github.com/jansalwowski/myspec/milestone/1).

## Before you start

| Requirement | Why |
|---|---|
| **myspec 2.12.0 or later** | 3.0 upgrades only from the last 2.x minor (RELEASING.md, "Upgrade base"). `update` refuses a lower version: check out the plugin at tag `v2.12.0`, start Claude with `--plugin-dir` pointing at that checkout, run `/myspec:update`, then return to the current plugin. A project still on 1.x goes through `v1.28.0` first, then `v2.12.0`; [upgrading-to-2.0.md](upgrading-to-2.0.md) covers that step. |
| **Claude Code 2.0.12 or later** | The hooks run from the plugin's `hooks.json` with `${CLAUDE_PLUGIN_ROOT}`, which arrived in 2.0.12. README "Installation" lists the sources. |
| **git 2.31 or later** | `git rev-parse --path-format=absolute`, which the memory scripts and the friction scan need. |
| **jq 1.6 or later** | Unchanged from 2.x. |

**Finish open sessions first.** 3.0 does not import in-flight 2.x session state.
Run `/myspec:session-complete` in every running session before `/myspec:update`.
A session that spans the upgrade starts unarmed (its
`/tmp/.myspec-session-writes-<id>` ledger is not read), is asked its isolation
decision again (`.claude/state/isolation/<id>.json` is not read), and loses its
feature-implement run (`.claude/state/implement-in-progress.json` is not read,
so the Stop gate blocks instead of warning). The files stay where they are;
delete them by hand.

Commit or stash first. `update` moves files, deletes files and edits the `hooks`
key of `.claude/settings.json`; a clean tree is what makes that reviewable.

```
/myspec:update
```

## What `update` does for you

Nothing in this section needs your attention unless the summary reports a
problem. Each migration runs once and is recorded in `.myspec.json`
`migrations`.

| Migration | What it does |
|---|---|
| `3.0.0-code-review` | Deletes the `codeReview` key from `.myspec.json`. Leaves `.claude/rules/code-review.md` alone and says so. |
| `3.0.0-plugin-hooks` | Removes the eight framework entries from `.claude/settings.json` `hooks` (by script name, whatever path prefix a 2.x install wrote) and leaves your own hooks in the same arrays alone. Moves the `.claude/hooks/` and `.claude/lib/` copies to `.claude/state/retired-3.0/` instead of deleting them, and names any copy whose hash differs from what v2.12.0 installed as "locally modified, compare before discarding". Drops `frameworkFiles` pins on `hooks/*` and `lib/*`. Files myspec never listed (`.claude/hooks/tests/`, your own helpers) are reported and left in place. `settings.local.json` is never edited: a framework entry there is reported for you to delete. |
| `3.0.0-reuse-audit` | Deletes the `reuseAudit` key from `.myspec.json`. When it held `enabled: false`, says how a tech-spec opts out now. |
| `3.0.0-memory-registry` | Rewrites a pre-1.28, pretty-printed `.claude/state/memory-ids.json` as the one-line form `memory-claim-id.sh` now reads, every floor kept (`memory-claim-id.sh --normalize`). |
| `3.0.0-schema-v2` | Deletes `project.description` (nothing read it) and records `hash` and `upstreamHash` on every pin in `frameworkFiles` (`lib/pin-reconcile.mjs --backfill`). |

Removals: the memory index headers `${aiDir}/.templates/index-{procedural,semantic,episodic}.md`
are deleted; `init` scaffolds the indexes once and `lib/memory-index.mjs`
maintains them. `frameworkVersion` now covers only the rules and the `${aiDir}`
files.

## What you have to check yourself

`update` never edits a file outside `manifest.json` beyond the steps above.
Everything below lives in files you own.

### 1. References to `.claude/lib/` and `.claude/hooks/`

The most likely breakage: a project hook, script or doc that calls a myspec
helper by its 2.x path now points at a file that is gone.

```bash
grep -rn "\.claude/lib/\|\.claude/hooks/" . --exclude-dir=.git --exclude-dir=state
```

Replace a myspec helper path with the plugin's `lib/<x>`. Inside a skill body,
write `${CLAUDE_PLUGIN_ROOT}/lib/<x>`, which Claude Code substitutes when it
loads the skill. Elsewhere, use the path a hook's block message prints: the
variable is not exported to commands run through the Bash tool, and a rule file
or an `${aiDir}` document gets no substitution.

### 2. Hook copies you patched

Look through `.claude/state/retired-3.0/` for any file the summary listed as
locally modified. A patch you still want goes back under a project name in
`.claude/hooks/`, wired by you in `.claude/settings.json`; a fix worth sharing
is worth an upstream issue. The rest can be deleted.

A teammate without the plugin enabled now gets no gates, as they already got no
skills. The doctor reports `hook-wired-locally` and `hook-copy-retired` until the
migration has run.

### 3. `.claude/rules/code-review.md`

The `code-review` skill and its `setup` blueprint are gone; Claude Code's
built-in `/code-review` replaces them. The rule file is yours: no manifest entry
ever tracked it, so `update` leaves it. It has no `paths:` gate, so Claude Code
loads it as project memory and its bullets are in context when the built-in
runs, but nothing reads its `## Standards` / `## Suppress` headings any more.
Keep it, reword it, or delete it. Replace `/myspec:code-review` in your own
files:

```bash
grep -rn "myspec:code-review" . --exclude-dir=.git
```

### 4. Opting a tech-spec out of the reuse audit

`reuseAudit.enabled` is gone. A tech-spec opts out by carrying
`<!-- myspec:reuse-audit skip: <reason> -->` anywhere in its text (a marker with
no reason is denied). Existing tech-specs without a `## Reuse audit` section are
not re-checked, so nothing needs editing now.

### 5. Container checks and provisioned worktrees

- A `.claude/verification.json` check that execs into a container needs `runIn`
  and a `containers` entry; the Stop gate no longer parses the command to guess.
  The doctor's `verification-exec-no-runin` warning names each check.
- Worktree provisioning writes `.claude/state/provision.json`, and the Stop gate
  compares that record instead of scanning for linked dependency directories.
  Re-provision a worktree made before the upgrade; the doctor reports
  `link-unrecorded` and `provision-stale`.

### 6. Pinned framework files

Every pin now carries `hash` and `upstreamHash`, so `update` can tell "upstream
moved under your pin" from "the pin always differed". A pin backfilled by the
migration cannot report the first case until the update after that. A
`marker-merge` file is hashed and compared on its framework-owned header only
(line 1 through `<!-- myspec:framework-end -->`), so your own content below the
marker never makes a pin look changed.

`update` now asks per pin instead of comparing sizes. A pin whose file equals
the plugin copy is offered for dropping; when you keep it, `update` records it
(`--record "<key>"`) so the next upstream change under it is raised. When you
pin a framework file by hand, run
`node "<plugin>/lib/pin-reconcile.mjs" --record "<key>"` afterwards.

### 7. Settings keys

`.myspec.json` is schema version 2. Every key it may hold is in
`lib/myspec-config.schema.json`, and `/myspec:doctor` reports any other as
`setting-unknown-key`. A `mockups` block is a setting now, so the doctor stops
warning on it. `orchestration.featureImplement`, `probes.portSource` and
`probes.scratchEnvScript` are recorded by the schema but not read yet.

### 8. Old skill names

The 2.0 redirect stubs are gone, and three skills left without one:

| Old | Use |
|---|---|
| `/myspec:features-status-audit` | `/myspec:feature-status-audit` |
| `/myspec:worktree-cleanup` | `/myspec:worktree-clean` |
| `/myspec:docs-sanitize` | `/myspec:doctor` surface C and `/myspec:session-clean` |
| `/myspec:feature-scenario` | `/myspec:feature-spec {feature} scenarios` (also offered after spec approval) |
| `/myspec:feature-seed-data` | `/myspec:feature-spec {feature} seed-data` |
| `/myspec:upstream-sync` | none: it was a maintainer workflow for the myspec repository and read nothing in a project |

```bash
grep -rn "features-status-audit\|worktree-cleanup\|docs-sanitize\|feature-scenario\|feature-seed-data\|upstream-sync" . --exclude-dir=.git
```

### 9. 1.x session leftovers

`update` cannot fix these, and since 2.0 nothing reads them:

- An `${aiDir}/memory/sessions/README.md` that documents an `active/` directory:
  live logs moved to `.claude/state/sessions/`. Rewrite or delete it.
- `.gitignore` lines for `${aiDir}/memory/sessions/active` (or `active/*`): drop
  them.
- A UUID-named log with `status: active` in `${aiDir}/memory/sessions/archive/`:
  a live log archived by hand or by a 1.x sweep. Finish it (`status: completed`,
  the `/myspec:session-complete` fields filled) or delete it; `session-clean`
  sweeps only untracked archive files.

## Behaviour changes with no file to grep

### Content gates judge the write, not the file

`no-absolute-paths`, `validate-frontmatter` and `require-reuse-audit` now run
before a Write or Edit lands and deny one whose proposed content breaks the
rule, instead of flagging the file afterwards. Only what the write adds or
changes is judged: a leaked path or a broken frontmatter already in the file no
longer blocks an edit elsewhere. A tech-spec is checked for its
`## Reuse audit` section when it is created and when a write changes that
section. A write the hooks cannot see (a Bash heredoc, `sed -i`, `tee`) is
checked by the Stop gate, with the same message, before the session ends.

The Stop gate judges only lines this session's Bash writes added.
`mark-code-changed.sh` now also runs at PreToolUse and PostToolUseFailure for
Bash: it snapshots each file the checks cover before and after the write, and
the gate judges the lines one of those before-to-after diffs added. A line the
file held before the session (committed or not), another session's line, and a
tech-spec that predates the session are never judged; a line this session
added and then committed still is. A write the scanner cannot see (a variable
path, a file `python3 -c` opens) gets no snapshot, as it gets no write event.
When the git object store is read-only, the snapshots are copied to
`.claude/state/sessions/<session_id>.blobs/`; `/myspec:session-clean` removes
that directory with the session file. [stop-gate.md](stop-gate.md) R14 has the
rules.

The hook now parses a Bash command at PreToolUse and again after it, so a long
command (hundreds of statements, many redirects into files) costs noticeably
more per call than in 2.x
([#277](https://github.com/jansalwowski/myspec/issues/277)).

### PreToolUse denials print `hookSpecificOutput` only

The framework's PreToolUse hooks no longer print the deprecated top-level
`decision`/`reason` pair beside `hookSpecificOutput.permissionDecision`. Tooling
of your own that parsed the old pair from a myspec hook must read
`hookSpecificOutput`. A hook started without `CLAUDE_PLUGIN_ROOT` (a stale copy)
denies or warns with "myspec lib missing" instead of approving silently.

### The Stop gate has one budget

The Stop hook lives in `lib/stop-gate/` and has a 300 s budget for the whole
stop, every check in every armed checkout included. A check that would start
after the budget is spent does not run, and the stop blocks naming it. A missing
or failing settings reader blocks the stop instead of guessing.
[stop-gate.md](stop-gate.md) holds the rules.

### Skills refuse the pre-plan shapes

- `feature-implement` refuses a plan carrying `orchestration: agent-chain`
  (retired in 2.0). Re-plan with `/myspec:feature-plan`.
- `feature-complete` requires `implementation-plan.md`; a feature without one
  stops instead of skipping the archive.
- `feature-spec-sync` and `.claude/rules/workflow.md` take completion only from
  `implementation-plan.md`, never from tech-spec checkboxes. An `in-progress`
  feature without a live plan is a mismatch.
- `mark-code-changed.sh` no longer adds `## Files touched` to a session log that
  lacks it; every log the hook or the template creates has it.
- A plan with no `### Milestone` heading still runs: that is the single-milestone
  form `feature-plan` emits.

## What 3.0 no longer carries

These carried a 1.x layout into 2.0. A project that ran the 2.12 `update` has
already been through every one of them.

| Dropped | What it did |
|---|---|
| Migrations `2.0.0-schema`, `2.0.0-doctor-rule`, `2.0.0-sessions`, `2.0.0-base-agents` | wrote `aiDir` and stripped per-file bookkeeping from `.myspec.json`; renamed `.claude/rules/ai-setup-audit.md` to `doctor.md`; moved live logs out of `${aiDir}/memory/sessions/active/`; offered to delete the user-scope `worker-base` / `reviewer-base` agents |
| `renamedFrom: "memory-index.md"` on `anti-patterns.md` | moved `${aiDir}/memory-index.md` to `${aiDir}/anti-patterns.md` |
| The five `removed` entries `since: "2.0.0"` | deleted `guard-git-branch.sh` (and unwired it), `${aiDir}/memory-system.md` and three unread templates |
| Doctor findings `myspec-schema-stale`, `doctor-rule-unrenamed`, `sessions-unmigrated` | reported a project the 2.0 migrations had not reached yet |
| Skill stubs `features-status-audit`, `worktree-cleanup`, `docs-sanitize` | named the 2.0 replacements |
