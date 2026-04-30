# memorify — nothing worth saving

Sometimes the right answer is "no memory." This example demonstrates the skill stopping cleanly instead of forcing a save.

## Setup

The user spent the session renaming a few CSS classes for visual consistency, fixing two typos in copy, and bumping a minor dependency. No surprises, no corrections, no decisions — pure cleanup work that's fully captured in the diff.

## Invocation

```
/memorify
```

## Skill flow

### 1. Sweep

The agent re-reads the conversation looking for:

- Reusable rules → none.
- Non-obvious facts → none; the renames are mechanical.
- Decisions or events → none; no architectural choice was made.
- User corrections → none; the user accepted every change as proposed.
- Validated approaches → nothing surprising; the changes were exactly what the diff implies.

Everything actionable from this session is *already* visible to a future agent reading the file or `git log`.

### 2. Reports back honestly

```
Nothing in this conversation feels worth remembering. The CSS renames,
typo fixes, and dep bump are all visible in the diff and don't carry
hidden context. No memory written.
```

The skill stops.

## Result

- No files written.
- No index changes.
- Final tally: **Saved 0 memories. Skipped 0.**

## Why this example matters

This is a deliberately **boring** example, and the lesson is exactly that:

- A "successful" `/memorify` run can write **zero** memories. The skill is allowed — encouraged — to say "nothing here."
- Forcing a memory in a session like this would either restate the diff (useless) or invent a "lesson" the user didn't actually internalize (worse than useless: it pollutes future searches).
- The bar for memory is **non-obvious + reusable**. Mechanical work that any future agent can re-derive by reading code doesn't clear it.

If you find `/memorify` consistently returns nothing on your work, that's not a bug — it means your sessions are mostly direct execution. Save `/memorify` for sessions that involved corrections, surprises, or decisions.
