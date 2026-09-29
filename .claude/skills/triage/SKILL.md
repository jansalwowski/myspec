---
name: "triage"
description: "Use when open myspec issues need triaging — labels, priority, repro on main, duplicates, splitting bundled reports, and batching ready issues for parallel work. Repo-local maintainer skill (not shipped with the plugin). Keywords: triage issues, issue backlog, label issues, what should I work on next, dedupe issues. Do NOT use to fix an issue or open a PR, or for downstream feature ideas (idea-intake)."
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
| `hooks/`, `hooks.json` | `area:hooks` |
| `lib/` | `area:lib` |
| `framework-files/`, `blueprints/`, `templates/`, the manifest | `area:framework-files` |
| `.claude-plugin/`, `.codex-plugin/`, `plugins/myspec/` | `area:plugin` |
| `scripts/`, `evals/`, `quality/`, `.github/`, `.githooks/`, `.claude/` | `area:tooling` |

A change to a mirrored tree also touches `plugins/myspec/` (AGENTS.md "Mirrored trees"). Don't add `area:plugin` for that; the mirror follows automatically.

## Workflow

### Step 1: Scope

With issue numbers as arguments, triage those. Otherwise take the open issues that carry `status:needs-triage` or no `status:*` label:

```bash
gh issue list --state open --limit 200 --json number,title,labels,body,createdAt,comments,milestone
```

It must exit 0. A non-zero exit is a failed step, never "nothing to triage". Filter with `jq`. With zero issues in scope, say so and stop.

Also load the comparison set for duplicate checks: issues of either state updated in the last 90 days (`--state all --search "updated:>=<date>"`), and merged PRs created since the oldest in-scope issue (`gh pr list --state merged --limit 100 --json number,title,mergedAt,files,closingIssuesReferences`).

### Step 2: Scratch checkout of main

Run `git fetch origin`, then `git worktree add --detach <scratchpad>/triage-main origin/main`. Use the session scratchpad directory, never the shared checkout: other sessions switch its branch, so a repro there tests whatever branch happens to be checked out. Every repro and every "is it still missing" grep in Step 3 runs in this tree. Step 6 removes it.

### Step 3: Assess each issue

Record one row per issue. The row holds type, areas, priority, status, the files the fix would touch, one line of evidence, and the proposed actions.

1. **Bundle.** Does the body hold two or more problems that would land as separate PRs, such as numbered findings with disjoint files or unrelated symptoms? If so, it gets `status:needs-split`. Draft one child issue per problem. Each child gets a component-prefixed title and its own repro, copied verbatim from the parent. The parent stays open as a tracker. Assess each child through items 2 to 6, not the parent.
2. **Duplicate or recurrence.** Compare with the comparison set by component and symptom, not by title wording. A duplicate of an open issue is closed with `--duplicate-of`, keeping the issue with the better repro. An item of a bundle that repeats another open issue becomes that issue, not a new child. A closed issue whose fix has regressed, or whose fix was partial, is a recurrence: link it in the comment and keep this one open.
3. **Already fixed.** Look for a merged PR after `createdAt` whose files overlap the named files or whose closing references include the issue. If you find one, rerun the repro to confirm, then propose closing as completed, citing the PR.
4. **Reproduce.** For a bug:
   - If the body gives a command or fixture, run it in the scratch tree. Record the command and whether it reproduced or not.
   - If there is no repro, try the behaviour the body describes, such as piping the named input into the named hook or running the named lib script.
   - If you cannot reproduce it, it gets `status:needs-repro`.
   - If it needs a consumer project, Docker or a live session, it gets `status:needs-repro` with the missing ingredient named. Don't guess.

   For an enhancement, check the premise instead: grep origin/main to confirm that what the issue calls missing is missing. Run only commands that stay inside the scratch tree or `$TMPDIR`. Never run a repro that pushes, deletes branches or writes outside them.
5. **Conflict.** Does the issue pull against another open issue, the next major's milestone plan, or a recently merged PR? Examples are removing a skill that a merged PR just fixed, or two issues editing the same rule in opposite directions. If so, it gets `status:blocked` on a decision, and the comment names both sides.
6. **Classify.** Set type, the areas from the table, priority from the `P1`–`P3` descriptions, and status. `status:ready` requires a reproduced bug or a confirmed premise. If breaking, add `breaking` and the next major's milestone (`gh api repos/{owner}/{repo}/milestones`), per RELEASING.md "Tracking".

With more than five issues in scope, dispatch one read-only subagent per issue for items 3 and 4. Give each the scratch tree path, the issue body and the comparison set. A subagent cannot reach the user. It returns `REPRO: <reproduced|not-reproduced|not-runnable> <command> — <one-line result>`, `FIXED-BY: #<pr>` when it finds a fix, and `NEED: <what would unblock>` for anything it could not settle. Items 1, 2, 5 and 6 stay with you, because they compare issues with each other.

### Step 4: Report and approve

Show one table with these columns: `#`, title, type, areas, P, status, evidence, proposed actions. Put P1 first. Below the table, show the drafted child issues for each split, then the work batches:

- A **work batch** is a set of `status:ready` issues whose touched files overlap. They go to one agent or branch, because two agents editing the same file collide.
- Batches with disjoint files can run in parallel. List each batch with its issues, the files it touches, and its highest priority.

Call `AskUserQuestion` with three options: apply everything, apply a subset (the user names the numbers), or apply nothing. Labels, comments, closes and new issues are all visible on GitHub, so nothing is written before this answer.

### Step 5: Apply

For each approved row, check that each command exits 0 and report any that fail:

- Labels: `gh issue edit N --add-label a,b --remove-label status:needs-triage`. Add `--milestone <name>` for breaking issues. When the title lacks a component prefix and one clearly applies, add `--title`.
- Splits: `gh issue create --title … --body … --label … --parent N` for each child, then comment on the parent listing the children.
- Duplicates: `gh issue close N --duplicate-of M --comment "<evidence>"`.
- Already fixed: `gh issue close N --reason completed --comment "Fixed by #<pr>; <repro command> no longer reproduces on <origin/main short sha>."`
- Comment only where a label alone does not explain the decision: needs-repro (what was tried), blocked (on what), and any close. Put the evidence line in the comment.

### Step 6: Verify and clean up

- Re-list the triaged issues. Each has exactly one `status:*` label, one `type:*` label and one priority, and none still carries `status:needs-triage` unless the user skipped it.
- `git worktree remove --force <scratchpad>/triage-main`, then `git worktree prune`.

## Rules

- Never close an issue without a comment carrying the evidence: the PR, the duplicate, or the repro that no longer fails.
- Never mark `status:ready` on reasoning alone. It needs a repro run or a premise grep on origin/main.
- Never raise an issue's priority to make it fit a batch, and never merge unrelated issues so that one agent takes them.
- Repro runs happen only in the scratch tree, never in the shared checkout or another session's worktree.

## Integration

**Called before** [OPTIONAL]: dispatching agents per work batch. Each batch becomes one branch; disjoint batches run in parallel.
**Reference** [REQUIRED]: `.github/labels.json` for label names and meanings, and RELEASING.md "Breaking changes" for the `breaking` test.
