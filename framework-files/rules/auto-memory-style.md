---
title: "Auto-Memory Style Guide"
purpose: "Length budget, cut list, and write-time consolidation for user-level auto-memory entries"
updated: 2026-09-02
---

# Auto-Memory Style Guide

Governs entries in the harness-managed user-level auto-memory store at
`~/.claude-personal/projects/<encoded_cwd>/memory/`. The lesson is the **rule**
plus the **trigger** plus the **minimal pattern**; everything else is a token
tax paid on every recall. The budget below applies at creation time and during
`/myspec:memory-sanitize` COMPRESS passes.

**Out of scope**: project-level myspec memory at `${aiDir}/memory/` — those use
their own typed templates in `${aiDir}/.templates/`.

## Length budget

| Type      | Body target | Hard cap |
|-----------|-------------|----------|
| feedback  | ≤ 12 lines  | 20       |
| project   | ≤ 15 lines  | 25       |
| semantic  | ≤  8 lines  | 15       |
| reference | ≤  6 lines  | 10       |

Index lines in `MEMORY.md`: ≤ 150 characters per line. Long index hooks bury
the takeaway.

## Keep (the essence)

| Element                  | Length      | Purpose                                                |
|--------------------------|-------------|--------------------------------------------------------|
| Rule statement           | 1 line      | What to do (or not do)                                 |
| Trigger / detection cue  | 1–2 lines   | How a future agent recognises this situation           |
| Why (only if non-obvious)| 1 line      | Skip when the rule is self-explanatory                 |
| How to apply             | 1–3 lines   | Minimal pattern, signature, or command                 |
| Critical caveat          | 1–2 lines   | Gotcha not findable in docs (magic numbers, edge case) |

## Cut (disposable)

- The originating incident ("user reported X after picking a point in Tver, Russia")
  — it's the seed, not the lesson
- Full code blocks when a one-line pattern, signature, or command suffices
- "Where applied: file:line, PR #X" — rots fast, `grep` finds current usage
- Framework-quirk subsections that restate the rule in different words
- Date-bound references ("as of 2026-04-30", commit SHAs, "in version X.Y") —
  rot fast and are rarely load-bearing

## Code blocks

- **One block max** per entry
- ≤ 6 lines
- Only when the pattern cannot be expressed in prose
- No imports, no boilerplate — just the load-bearing call

A worked before/after compression lives in `examples/skills/memory-sanitize.md`
(41 lines → 11, no actionable content lost).

## Pre-write consolidation (ADD / UPDATE / NO-OP)

Before writing a new auto-memory file:

1. Read `MEMORY.md` — scan hook lines for keyword overlap with the planned entry
2. For each candidate hit, read the linked file's body
3. Decide:
   - **NO-OP** — an existing memory already covers this. Tell the user
     "Already covered by `{file}` — open it?" and skip writing.
   - **UPDATE** — an existing memory is close but missing this nuance. Propose
     a verbatim diff (new lines to append/insert into the existing file). Do
     not create a new file.
   - **ADD** — truly novel. Write a new file respecting the length budget above.

Never write a new file when an UPDATE fits. Append-style growth is the bloat path.

## Conflict resolution

When two KEEP memories contradict (e.g., one says "always do X", another says
"never do X when Y"):

- Newer wins.
- Older becomes `status: superseded` in its frontmatter, body collapses to a
  single line: `Superseded by [{survivor-filename}](./{survivor-filename}).`
- Remove the older entry from `MEMORY.md`.
- Keep the file on disk as an audit trail.

This is non-destructive: history is preserved, but only the current rule is
indexed and recallable.
