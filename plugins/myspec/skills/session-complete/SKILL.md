---
name: "session-complete"
description: >
  Use when a tracked work session is finished and ready to be archived.
  Keywords: end session, finish session, wrap up, close session, session
  done, archive session, extract memories. Pairs with the mark-code-changed.sh
  hook that auto-creates active session files on first code edit. Do NOT use
  mid-implementation, for abandoned sessions, or for quick fixes that left no
  active session file.
---

# Session Complete

## Prerequisites

Requires at least one file in `${aiDir}/memory/sessions/active/` (excluding `.gitkeep`).

## Workflow

### 1. Identify Target Session

List `${aiDir}/memory/sessions/active/*.md` (excluding `.gitkeep`).

- **Zero files**: Abort. Tell user: "No active sessions found. Either no code was edited this session (the hook only auto-creates on code edits) or all sessions were already archived. Use `/myspec:session-start` to create one manually."
- **Exactly one file**: Use it.
- **Multiple files**: Pick the file with the latest mtime as the most likely target. Show the user a list of all active files (`session_id` prefix + topic + cwd + age) and confirm before proceeding. Multiple-active is normal in multi-agent workflows where subagents created their own sessions.

Set `TARGET_FILE` to the chosen file path. Do NOT touch sibling active files.

### 2. Update Session Log

Edit `TARGET_FILE`:

1. Set `status: completed` in frontmatter
2. Refine `topic` if it still starts with `auto:` (auto-created sessions need a real topic before archive)
3. Fill the **Outcome** section with:
   - What worked (the successful solution)
   - What was the root cause of the issue (if applicable)
   - Key insights discovered

### 3. Analyze Session for Typed Extractions

Review the log table, paying attention to Type column hints:

- `P` entries with ✅ or ❌ → candidate procedural memories
- `S` entries with 💡 → candidate semantic facts
- Significant decisions or events → candidate episodic memories

### 4. Propose Extractions to User

If no candidates meet the threshold (all trivial or duplicates), report: "No memories worth extracting from this session." and skip to step 6.

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

### 5. Create Approved Memories

For each approved extraction:
→ Invoke `/myspec:memory-create` (REQUIRED) with `type` parameter (procedural/semantic/episodic)
→ Pass the relevant log entries and context

### 6. Archive Session

Move `TARGET_FILE` to:
`${aiDir}/memory/sessions/archive/YYYY-MM-DD-{slug}.md`

Where slug is derived from the (refined) topic — never archive with `auto:` in the slug.

**Slug format**: Use lowercase with hyphens, derived from the topic. Examples:
- "Fix StreetView not updating" → `YYYY-MM-DD-fix-streetview-updating.md`
- "Implement marker clustering" → `YYYY-MM-DD-implement-marker-clustering.md`

If the slug would collide with an existing archive file, append a short session_id prefix: `YYYY-MM-DD-{slug}-{session_id_first8}.md`.

### 7. Confirm Completion

Report to user:
- Number of memories created (by type)
- Archive location

## When NOT to Use

- Work is not finished (still implementing, debugging, or testing)
- Session was abandoned without resolution (use `status: abandoned` and let `/myspec:bootstrap` auto-archive it on next session)
- Quick tasks where no session log was created

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

- [ ] `TARGET_FILE` no longer exists at `${aiDir}/memory/sessions/active/`
- [ ] Sibling active sessions (other agents) were NOT touched
- [ ] Archive file exists at `${aiDir}/memory/sessions/archive/YYYY-MM-DD-{slug}.md` with `status: completed`
- [ ] Outcome section is filled (what worked, root cause, key insights)
- [ ] Approved memories were created via `/myspec:memory-create` (check respective index files)
- [ ] User was presented extraction list and confirmed selections
