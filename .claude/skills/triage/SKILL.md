---
name: "triage"
description: "Use when open myspec issues need triaging — labels, priority, repro on main, duplicates, splitting bundled reports, and batching ready issues for parallel work — or when the open PR queue needs analysis: collisions, stacks, merge order (argument `prs`). Repo-local maintainer skill (not shipped with the plugin). Keywords: triage issues, issue backlog, label issues, what should I work on next, dedupe issues, PR queue, merge order. Do NOT use to fix an issue or open a PR, to review one PR's code (review-pr), or for downstream feature ideas (idea-intake)."
---

# Triage

Triage the myspec repo's open GitHub issues. Repo-local maintainer skill: it lives in `.claude/skills/`, is not shipped in the plugin, and is useless in consumer projects. The `issue-triage` workflow has already added area labels from each title's component prefix and `status:needs-triage`; this skill supplies the judgement a workflow cannot.

Triage and fix are separate turns. This skill reads, reproduces and labels. It never edits code, opens a PR or pushes a branch.

**Announce at start:** "Triaging myspec issues."

## Prerequisites

- In the myspec repo: `.github/labels.json` and `scripts/triage/area-labels.mjs` exist at repo root. If not, stop.
- `gh` authenticated, with a version whose `gh issue edit --help` lists `--parent` and `gh issue close --help` lists `--duplicate-of` (2.94 has both). `jq` installed.
- Labels in sync: every name in `.github/labels.json` appears in `gh label list --limit 500 --json name`. If not, run `scripts/triage/sync-labels.sh --dry-run`, show the output, and apply it only on the user's go.

## Label scheme

`.github/labels.json` is the source of truth and holds each label's meaning in its description. Apply exactly one `type:*` label, every `area:*` label the fix would touch, one of `P1`/`P2`/`P3`, and exactly one `status:*` label. Apply `breaking` only when RELEASING.md's "Breaking changes" definition holds. A change that ships its own migration (`renamedFrom`, `removed`) is not breaking.

| Path the fix touches | Area |
|---|---|
| `skills/` | `area:skills` |
| `hooks/` | `area:hooks` |
| `lib/` | `area:lib` |
| `framework-files/`, `blueprints/`, `templates/`, the manifest | `area:framework-files` |
| `.claude-plugin/` | `area:plugin` |
| `scripts/`, `evals/`, `quality/`, `.github/`, `.githooks/`, `.claude/` | `area:tooling` |

## Workflow

### Step 1: Scope

With `prs` as the argument, run [PR mode](#pr-mode) instead. With issue numbers as arguments, triage those. Otherwise take the open issues that carry `status:needs-triage` or no `status:*` label:

```bash
gh issue list --state open --limit 200 --json number,title,labels,body,createdAt,comments,milestone
```

It must exit 0. A non-zero exit is a failed step, never "nothing to triage". Filter with `jq`. With zero issues in scope, say so and stop.

A tracker whose last sub-issue closed comes back with `status:needs-triage` and an *All sub-issues are closed* comment from the workflow (`scripts/triage/tracker-check.sh`). Read its mapping comment and skip Step 3 for it. If every section went to a closed child, an existing issue, or "already fixed", propose closing it as completed. Otherwise the leftover sections go through Step 3 like a new bundle.

Also load the comparison set for duplicate checks: issues of either state updated in the last 90 days (`--state all --search "updated:>=<date>"`), and merged PRs created since the oldest in-scope issue (`gh pr list --state merged --limit 100 --json number,title,mergedAt,files,closingIssuesReferences`).

### Step 2: Scratch checkout of main

Run `git fetch origin`, then `git worktree add --detach <scratchpad>/triage-main origin/main`. Use the session scratchpad directory, never the shared checkout: other sessions switch its branch, so a repro there tests whatever branch happens to be checked out. Every repro and every "is it still missing" grep in Step 3 runs in this tree. Step 6 removes it.

### Step 3: Assess each issue

Record one row per issue. The row holds type, areas, priority, status, the files the fix would touch, one line of evidence, and the proposed actions.

1. **Bundle.** Does the body hold two or more problems that would land as separate PRs, such as numbered findings with disjoint files or unrelated symptoms? If so, draft one child issue per problem. Each child gets a component-prefixed title, and its section of the parent copied verbatim, repro included. Assess each child through items 2 to 6, not the parent. Each item of the bundle ends up in one of three places:
   - a new child issue
   - an existing issue, when the item repeats one (item 2); comment on that issue with the item's evidence
   - the parent's comment, when the item is already fixed (item 3) or needs no change

   The parent stays open as a tracker: `status:blocked` on its children, its highest child's priority, and a comment that maps every section to where it went. `status:needs-split` is only for a bundle the user did not approve splitting.
2. **Duplicate or recurrence.** Compare with the comparison set by component and symptom, not by title wording. Two bundles from different sessions often report the same defect in different words. A duplicate of an open issue is closed with `--duplicate-of`, keeping the issue with the better repro. A closed issue whose fix has regressed, or whose fix was partial, is a recurrence: link it in the comment and keep this one open.
3. **Already fixed.** Look for a merged PR after `createdAt` whose files overlap the named files or whose closing references include the issue. When the report names the version it was found on (a downstream doctor run), `git tag --contains <merge sha>` shows whether that version had the fix. If you find a fix, rerun the repro to confirm, then propose closing as completed, citing the PR and the first tag that contains it.
4. **Reproduce.** For a bug:
   - If the body gives a command or fixture, run it in the scratch tree. Record the command and whether it reproduced or not.
   - If there is no repro, try the behaviour the body describes, such as piping the named input into the named hook or running the named lib script.
   - If you cannot reproduce it, it gets `status:needs-repro`.
   - If it needs a consumer project, Docker or a live session, it gets `status:needs-repro` with the missing ingredient named. Don't guess.

   For an enhancement, check the premise instead: grep origin/main to confirm that what the issue calls missing is missing. Where the body misstates the code (a wrong line, a wrong command, a behaviour that is partly there), put the correction in the triage comment, because whoever fixes the issue trusts the body. Run only commands that stay inside the scratch tree or `$TMPDIR`. Never run a repro that pushes, deletes branches or writes outside them. Build fixture repos under `$(cd "$TMPDIR" && pwd -P)`. On macOS `$TMPDIR` sits under a `/var` symlink, and hooks that compare paths against the repo root then treat every file as outside the repo and approve it. That is a false "not reproduced".
5. **Conflict.** Does the issue pull against another open issue, the next major's milestone plan, or a recently merged PR? Examples are removing a skill that a merged PR just fixed, or two issues editing the same rule in opposite directions. If so, it gets `status:blocked` on a decision, and the comment names both sides.
6. **Classify.** Set type, the areas from the table, priority from the `P1`–`P3` descriptions, and status. `status:ready` requires a reproduced bug or a confirmed premise. If breaking, add `breaking` and the next major's milestone (`gh api repos/{owner}/{repo}/milestones`), per RELEASING.md "Tracking".

With more than five issues or bundle items in scope, split items 1 and 2 first, then dispatch read-only subagents for items 3 and 4. Group the items by the files they name, one subagent per group, keeping to about six. Issues are the wrong unit: one bundle can hold ten items, and an item from one issue often shares a hook with an item from another.

Give each subagent:
- the scratch tree path
- the claims, quoted with their item ids
- the fixture-path rule from item 4

A subagent cannot reach the user. For each item it returns:
- `REPRO: <reproduced|not-reproduced|partial|not-runnable> <command> — <one-line result>`
- `FILES: <files the fix would touch, tests included>`, which the work batches need
- `FIXED-BY: #<pr>`, when it finds a fix
- `NEED: <what would unblock>`, for anything it could not settle

Items 1, 2, 5 and 6 stay with you, because they compare issues with each other.

### Step 4: Report and approve

Show one table with these columns: `#`, title, type, areas, P, status, evidence, proposed actions. Put P1 first. Below the table, show the drafted child issues for each split, then the work batches:

- A **work batch** is a set of `status:ready` issues whose touched files overlap. They go to one agent or branch, because two agents editing the same file collide.
- Batches with disjoint files can run in parallel. List each batch with its issues, the files it touches, and its highest priority.

Call `AskUserQuestion` with three options: apply everything, apply a subset (the user names the numbers), or apply nothing. Labels, comments, closes and new issues are all visible on GitHub, so nothing is written before this answer.

### Step 5: Apply

For each approved row, check that each command exits 0 and report any that fail:

- Labels: `gh issue edit N --add-label a,b --remove-label status:needs-triage`. Add `--milestone <name>` for breaking issues. When the title lacks a component prefix and one clearly applies, add `--title`.
- Splits: `gh issue create --title … --body-file … --label … --parent N` for each child, with its final labels including a `status:*` one. The `issue-triage` workflow then adds no `status:needs-triage`, so it doesn't re-queue the child. Write each body to a file first: a verbatim section full of backticks and quotes doesn't survive `--body "…"`. Comment on the parent only after every child exists, because the comment cites their numbers.
- Items folded into an existing issue: comment on that issue with the item's section and evidence.
- Duplicates: `gh issue close N --duplicate-of M --comment "<evidence>"`.
- Already fixed: `gh issue close N --reason completed --comment "Fixed by #<pr>; <repro command> no longer reproduces on <origin/main short sha>."`
- Comment only where a label alone does not explain the decision: needs-repro (what was tried), blocked (on what), a folded item, a corrected body, and any close. Put the evidence line in the comment.

### Step 6: Verify and clean up

- Re-list the triaged issues and the new children. Each has exactly one `status:*` label, one `type:*` label and one priority, and none still carries `status:needs-triage` unless the user skipped it. `gh run list --workflow issue-triage.yml` shows a successful run for each child.
- `git worktree remove --force <scratchpad>/triage-main`, then `git worktree prune`.

## PR mode

With `prs` as the argument, analyse the open PR queue instead of the issues. It reads everything and writes only after the approval in PR-mode step 5 below; issue-mode Steps 2–6 do not run. It never merges, approves, closes or pushes: `review-pr` reviews one PR's code, and a merge needs the maintainer's go per batch.

1. **Load.** `gh pr list --state open --limit 100 --json number,title,body,headRefName,baseRefName,isDraft,mergeStateStatus,reviewDecision,labels,files,closingIssuesReferences,updatedAt,statusCheckRollup` must exit 0. With zero PRs, say so and stop. Also load the open `status:ready` issues.
2. **Per PR**, record:
   - **Stack.** A base other than `main` names a parent. Step 1 loads only open PRs, so look it up with `gh pr list --state all --head <base> --json number,state` (must exit 0). `OPEN`: the child waits for it. `MERGED`: propose retargeting the child with `gh api -X PATCH repos/<owner>/<repo>/pulls/<n> -f base=main` (AGENTS.md "Stacked PRs"). `CLOSED` or no PR: never retarget, because the child still carries the parent's unreviewed commits and retargeting puts them in front of main; report it for the maintainer to decide.
   - **Merge state.** `mergeStateStatus` (`CLEAN`, `BEHIND`, `DIRTY`, `BLOCKED`, `UNSTABLE`, `HAS_HOOKS`, `DRAFT`, `UNKNOWN`), and failing checks by name from `statusCheckRollup`. `UNKNOWN` means GitHub has not computed it yet: re-read it with `gh pr view <n> --json mergeStateStatus` before ordering, and report it as unknown if it stays so.
   - **Issues.** Each closing issue and its `status:*`. Note a PR that closes a `status:blocked` or `status:needs-repro` issue, and a `fix` PR that closes none.
   - **Labels.** Run `node scripts/triage/pr-labels.mjs --title "<title>" --body-file <body> < <changed files>` and compare. A label it prints that the PR lacks means the `pr-labels` workflow didn't run or failed; check `gh run list --workflow pr-labels.yml`. A missing `type:*` or `area:*` the script doesn't print is by design (`chore`, `ci`, `refactor`, `test` titles get no type; root-only files get no area), so it is not a finding.
   - **Companions.** `gh api --paginate repos/<owner>/<repo>/pulls/<n>/files | jq -s 'add // []' | node scripts/triage/pr-companions.mjs --body-file <body>`, with the body written to a file first.
   - **Stale.** A draft, or no update in 7 days.
3. **Across PRs**, find:
   - **Collisions:** two open PRs whose changed files overlap. List the shared files, because the second PR to merge rebases over them.
   - **Duplicate work:** two PRs closing the same issue.
   - **Ready work with no PR:** the `status:ready` issues that no open PR closes, grouped by `area:*` label. File-level work batches come from issue mode, which PR mode does not run.
4. **Report** one table with these columns: `#`, title, base, merge state, failing checks, closed issues, labels, notes. Below it, list the collisions, then a merge order: a parent before its child, then P1 first, then `CLEAN` before `BEHIND` or `DIRTY`. Then list the ready issues that have no PR.
5. **Approve and apply.** Call `AskUserQuestion` with three options: apply everything, apply a subset, or apply nothing. The possible writes are adding missing labels (through `gh api repos/<owner>/<repo>/issues/<n>/labels`, since `gh pr edit` fails with this repo's token), retargeting a child whose parent is `MERGED`, and commenting on colliding PRs to name the shared files. Each command must exit 0.

## Rules

- Never close an issue without a comment carrying the evidence: the PR, the duplicate, or the repro that no longer fails.
- Never mark `status:ready` on reasoning alone. It needs a repro run or a premise grep on origin/main.
- Never raise an issue's priority to make it fit a batch, and never merge unrelated issues so that one agent takes them.
- Repro runs happen only in the scratch tree, never in the shared checkout or another session's worktree.

## Integration

**Called before** [OPTIONAL]: dispatching agents per work batch. Each batch becomes one branch; disjoint batches run in parallel.
**Reference** [REQUIRED]: `.github/labels.json` for label names and meanings, and RELEASING.md "Breaking changes" for the `breaking` test.
