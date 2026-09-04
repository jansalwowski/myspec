# Upgrading to myspec 2.0

`/myspec:update` does the mechanical work. This page covers the rest — the
changes that live in files myspec does not own, and the behaviour changes that
have no file to grep at all.

Read it after the update run, with the summary it printed still on screen.

## Before you start

2.0 upgrades from **1.28.0 or later**. `update` refuses a lower version and tells
you how to step through 1.28 first: check out the plugin at tag `v1.28.0`, start
Claude with `--plugin-dir` pointing at that checkout, run `/myspec:update`, then
return to the current plugin.

Commit or stash first. `update` moves files, deletes files, and edits the `hooks`
key of `.claude/settings.json`; a clean tree is what makes that reviewable.

```
/myspec:update
```

## What `update` does for you

Nothing in this section needs your attention unless the summary reports a
problem.

| | |
|---|---|
| `.myspec.json` schema | `aiDir` normalised (trailing slash stripped, key made required), per-file `version`/`lastUpdated` bookkeeping dropped — the block holds pins only |
| Live session logs | moved from `{aiDir}/memory/sessions/active/` to `.claude/state/sessions/`; `archive/` stays put |
| `.claude/rules/ai-setup-audit.md` | renamed to `doctor.md` |
| `{aiDir}/memory-index.md` | renamed to `anti-patterns.md`, your content below the marker preserved |
| Retired files | `guard-git-branch.sh`, `{aiDir}/memory-system.md`, and three unread templates deleted |
| Hook wiring | `.claude/settings.json` `hooks` key deep-merged: the removed hook unwired, the two new `PreToolUse` hooks registered |
| User-scope agents | the six inert `worker-base` / `reviewer-base` files offered for deletion |

## What you have to check yourself

`update` never edits a file outside `manifest.json`. Everything below lives in
files you own.

### 1. References to the old session path

The single most likely breakage, because project hooks reach for it directly.

```bash
grep -rn "memory/sessions/active" . --exclude-dir=.git
```

Live logs are now `.claude/state/sessions/<session_id>.md` in the **primary
checkout** (gitignored). `{aiDir}/memory/sessions/archive/` is unchanged — that
is still committed, curated knowledge.

If you wrote a hook that carved out an exception so a worktree session could
still write into the main checkout's `memory/sessions/`, that carve-out is now
dead code: `.claude/state/` is outside `${aiDir}` and outside git.

### 2. References to renamed skills

Stubs keep the old slash commands working for one minor cycle, then they go.
Your own files are not covered by them.

```bash
grep -rn "features-status-audit\|worktree-cleanup\|docs-sanitize" . --exclude-dir=.git
```

| Old | New |
|---|---|
| `/myspec:features-status-audit` | `/myspec:feature-status-audit` |
| `/myspec:worktree-cleanup` | `/myspec:worktree-clean` |
| `/myspec:docs-sanitize` | retired — naming and dead references are `/myspec:doctor` surface C; misplaced session files are `/myspec:session-clean` |

Check your `CLAUDE.md`, your own skills, `.claude/commands/`, and any script or
CI job that invokes myspec by name.

### 3. Local forks of the isolation hooks

If you pinned or hand-edited `guard-git-branch.sh`, that hook no longer exists.
Its branch-mutation guard now lives in `guard-worktree-context.sh`, alongside the
build- and install-targeting guard, and `require-isolation-decision.sh` blocks
the first source edit until the session records where it is working.

Clear the obsolete pins from `.myspec.json` so `update` can manage the
replacements.

### 4. Pinned rules that upstream has since shrunk

2.0 trimmed the always-loaded rules and path-gated the rest. If you pinned one
for its size, the pin is now the expensive copy. `update` offers a keep / take /
diff choice per pin, and the setup doctor names it directly:

```
WARN over-budget-pinned: .claude/rules/workflow.md: ~3410 tokens against a ~1000
     budget, and pinned in .myspec.json ("trimmed for always-loaded context
     budget") — update skips it, so it stays over budget until the pin is
     cleared. The plugin copy is now smaller (~922 tokens), so the pin costs
     more than it saves.
```

## Behaviour changes with no file to grep

### Implementers no longer run their own tests

The biggest change to how `feature-implement` behaves, and the one with no
error message.

An implementer subagent writes code, writes tests, and commits. It does **not**
run the task's test, lint, type-check, build, or install commands. The phase
reviewer runs them once, for the whole phase, and its run is the only one.

The reason is narrow: an implementer that can run its own gate can also weaken
it, and the cheapest way past a failing gate is always to change the gate —
loosen the assertion, widen the type, add the disable, skip the test. Each is a
local success and a silent defect.

**If you have a plan written under 1.x**, its task blocks probably carry
`Step 2: Run test — expect FAIL` steps. Those steps now have no owner. Replace
them with a `**Verify at phase review:**` line naming the command; the reviewer
reads it per task. New plans from `/myspec:feature-plan` do this already.

### Orchestrator agent-chain mode is gone

`feature-plan` no longer offers it and `feature-implement` no longer dispatches
it. An existing plan carrying `orchestration: agent-chain` still runs — as a
normal plan, with one line saying so. The `roles:` block and any
`**Step N (Worker|Reviewer|Controller):**` annotations are ignored; the step
text still applies.

If you kept a local note telling agents to pick `normal-fallback` in this repo,
it is now describing the only mode there is.

### `MYSPEC_ALLOW_LINKED_MODULES` has a config form

The Stop hook still honours the environment variable, so nothing breaks. The
preferred form is `isolation.allowLinkedModules: true` in `.myspec.json`, which
travels with the repo instead of with whoever remembered to export it.

## When you are done

```
/myspec:doctor
```

Zero errors is the bar. Warnings about your own content — an oversized
`CLAUDE.md`, empty verification commands — are yours to triage; anything naming
a framework file is worth reporting upstream.
