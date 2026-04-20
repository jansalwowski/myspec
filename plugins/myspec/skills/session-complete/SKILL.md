---
name: "session-complete"
description: >
  Use when work session is finished. Keywords: end session, finish session,
  wrap up, close session, session done. Handles session archival and memory
  extraction from session logs. Requires active session from /session-start.
  Do NOT use mid-implementation, for abandoned sessions, or for quick tasks
  that didn't use /session-start.
---

# Session Complete

## Prerequisites

Requires an active `${aiDir}/memory/sessions/active.md` file. If missing, abort and inform user: "No active session found. Use /myspec:session-start first or archive manually."

## Workflow

### 1. Update Session Log

Check that `${aiDir}/memory/sessions/active.md` exists. If missing, inform user: "No active session found. Use /myspec:session-start first or archive manually." and stop.

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

If no candidates meet the threshold (all trivial or duplicates), report: "No memories worth extracting from this session." and skip to step 5.

Otherwise, present a numbered list:

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
→ Invoke `/myspec:memory-create` (REQUIRED) with `type` parameter (procedural/semantic/episodic)
→ Pass the relevant log entries and context

### 5. Archive Session

Move `${aiDir}/memory/sessions/active.md` to:
`${aiDir}/memory/sessions/archive/YYYY-MM-DD-{slug}.md`

Where slug is derived from the topic.

**Slug format**: Use lowercase with hyphens, derived from the topic. Examples:
- "Fix StreetView not updating" → `YYYY-MM-DD-fix-streetview-updating.md`
- "Implement marker clustering" → `YYYY-MM-DD-implement-marker-clustering.md`

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

**What worked**: Destroying and recreating the StreetView instance instead of updating props.

**Root cause**: Google Maps StreetView API caches internal state that persists when props are updated. Only a full teardown (`destroyStreetView()` + `await nextTick()` + `createStreetView()`) resets the cached state.

**Key insights**:
- Updating :key on the component wrapper doesn't destroy the Google Maps instance
- The API's refresh methods don't clear cached coverage dates
- Always verify `streetViewInstance !== null` after recreation
```

## Verification Checklist

- [ ] `${aiDir}/memory/sessions/active.md` no longer exists (was archived)
- [ ] Archive file exists at `${aiDir}/memory/sessions/archive/YYYY-MM-DD-{slug}.md` with `status: completed`
- [ ] Outcome section is filled (what worked, root cause, key insights)
- [ ] Approved memories were created via `/myspec:memory-create` (check respective index files)
- [ ] User was presented extraction list and confirmed selections
