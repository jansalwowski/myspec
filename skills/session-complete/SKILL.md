---
description: "Use when work session is finished. Archives session log, proposes multi-type memory extractions, invokes /myspec:memory-create for approved entries. Do NOT use mid-implementation, for abandoned sessions, or for quick tasks that didn't use /myspec:session-start."
---

# Session Complete

## Path Resolution

1. Read `.myspec.json` from project root
2. Extract `aiDir` value (e.g., ".ai" or "ai")
3. All paths below use `${aiDir}` — resolve before use
4. If `.myspec.json` not found: STOP and tell user to run `/myspec:init`

## Prerequisites

You must have an active `${aiDir}/memory/sessions/active.md` file.

## Procedure

### 1. Update Session Log

Edit `${aiDir}/memory/sessions/active.md`:

1. Set `status: completed` in frontmatter
2. Fill the **Outcome** section with:
   - What worked (the successful solution)
   - What was the root cause of the issue (if applicable)
   - Key insights discovered

### 2. Analyze Session for Typed Extractions

Review the log table, paying attention to Type column hints:

- `P` entries with ✅ or ❌ → candidate procedural memories
- `S` entries with 💡 → candidate semantic facts
- Significant decisions or events → candidate episodic memories

### 3. Propose Extractions to User

Present a numbered list:

```
Session complete. N potential memories:

1. [semantic] <one-line fact description>
2. [procedural] <one-line pattern description>
3. [episodic] <one-line event description>

Save all / select (e.g., "1,3") / skip?
```

Filter out:
- Trivial findings (typos, obvious config)
- Things that aren't non-obvious
- Duplicates of existing memories (check indexes first)

### 4. Create Approved Memories

For each approved extraction:
> Invoke `/myspec:memory-create` with `type` parameter (procedural/semantic/episodic)
> Pass the relevant log entries and context

### 5. Archive Session

Move `${aiDir}/memory/sessions/active.md` to:
`${aiDir}/memory/sessions/archive/YYYY-MM-DD-{slug}.md`

Where slug is derived from the topic.

**Slug format**: Use lowercase with hyphens, derived from the topic. Examples:
- "Fix auth not updating" → `YYYY-MM-DD-fix-auth-updating.md`
- "Implement caching layer" → `YYYY-MM-DD-implement-caching-layer.md`

### 6. Confirm Completion

Report to user:
- Number of memories created (by type)
- Archive location

## When NOT to Use

- Work is not finished (still implementing, debugging, or testing)
- Session was abandoned without resolution (use `status: abandoned` and archive manually)
- Quick tasks that didn't need a session log

## Example Outcome Section

```markdown
## Outcome

**What worked**: Destroying and recreating the service instance instead of updating props.

**Root cause**: The third-party API caches internal state that persists when props are updated. Only a full teardown + await + recreation resets the cached state.

**Key insights**:
- Updating the component wrapper key doesn't destroy the underlying API instance
- The API's refresh methods don't clear cached state
- Always verify the instance is not null after recreation
```
