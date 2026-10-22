# `/myspec:housekeep` — examples

The everyday sweep in one script call: removes what a rule proves safe, counts what needs judgement, and names the skill that asks about it. It never prompts. A SessionStart hook prints one line when it has not run for 7 days.

> **Related**: `/myspec:worktree-clean` and [`/myspec:session-clean`](session-clean.md) ask per item; housekeep runs only their provable-safe part and points at them for the rest.

**Contents**

- [Weekly nudge — routine sweep](#weekly-nudge--routine-sweep)
- [Dry run before a big cleanup](#dry-run-before-a-big-cleanup)
- [A branch held back](#a-branch-held-back)

---

## Weekly nudge — routine sweep

### Setup

A session starts and the hook prints:

```
myspec: housekeep last ran 9 days ago. Run /myspec:housekeep to clear merged branches, stale session state and idle brainstorm sessions.
```

Since the last run, three PRs were squash-merged, a dozen sessions came and went, and a brainstorm session from last week sits in `.myspec/brainstorm/`.

### Invocation

```
/myspec:housekeep
```

### Output

```
branches: removed 3 merged (feat/export-csv, fix/invoice-rounding, docs/readme-badges); 4 kept
sessions: removed 11 state file(s) older than 24h; 2 live log(s) older than 6h, run /myspec:session-clean
brainstorm: removed 1 session(s) idle over 7d; 0 kept
memory: 0 error(s), 3 warning(s), run /myspec:memory-optimize
```

The agent shows the lines as printed and offers the two follow-ups in one line: "Two live logs and three memory warnings need a decision. Run `/myspec:session-clean` or `/myspec:memory-optimize`?" It runs neither on its own.

---

## Dry run before a big cleanup

### Setup

The user returns to a repository after a month and wants to see what would go first.

### Invocation

```
/myspec:housekeep — just show me what it would remove
```

The agent runs `housekeep.sh --dry-run`. Every line reads `would remove`, nothing is deleted, and the timestamp is not written, so the next session still nudges.

---

## A branch held back

### Setup

`feat/pdf-export` was merged as PR #212, then two more commits landed on the local branch.

### Output

```
branches: removed 2 merged (fix/tz-offset, chore/bump-deps); 1 kept
```

The user asks why `feat/pdf-export` is still there. The agent does not delete it: the script found no containment proof. It points at `/myspec:worktree-clean`, whose audit names the hold (`PR #212 merged but local tip … != PR head …`) and asks.
