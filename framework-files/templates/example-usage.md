---
title: "Memory System Example Usage"
purpose: "Demonstrates type-aware memory system workflow with procedural, semantic, and episodic types"
updated: 2026-03-24
version: 3.0
---

# Memory System Example Usage

This document shows how the type-aware memory system works in practice, with three memory types (procedural, semantic, episodic) stored in `${aiDir}/memory/{type}/`.

## Scenario: API Response Caching Bug

### 1. Starting Work

Agent receives task: "Fix API responses - cached data persists after user changes settings"

**Pre-flight checklist:**
```
Read ${aiDir}/memory/index.md (Layer 1 global index)
Read ${aiDir}/pre-flight.md
No existing ${aiDir}/memory/sessions/active.md
Scan ${aiDir}/memory/procedural/index.md — keyword match!
Scan ${aiDir}/memory/semantic/index.md — no match
Scan ${aiDir}/memory/episodic/index.md — no match
```

**From procedural/index.md:**
```markdown
| ID | Use When | Handles | Not For |
|----|----------|---------|---------|
| P009 | cache, stale data, settings change | Cache invalidation, state reset | initial load, cold start |
```

**Keywords match task!** Agent:
1. Sees "cache" and "stale data" in "Use When" column
2. Checks "Not For" - confirms not initial load (it's an update)
3. Reads `${aiDir}/memory/procedural/P009-cache-invalidation.md`

### 2. Applying Memory

Memory file leads with **Procedure** section (not "What Fails"):
1. Clear the relevant cache store after settings mutation
2. Wait for cache flush to complete
3. Re-fetch affected data
4. **Verify**: Check response contains updated values

Agent follows procedure directly, skipping multiple failed attempts at partial cache updates.

### 3. Session Log (Success Case)

```markdown
---
topic: "Fix stale cached API responses"
mode: bugfix
started: 2024-01-15 14:30
status: completed
---

# Session: Fix Stale Cache After Settings Change

## Context
API returns cached data after user changes settings.

## Log
| # | Action | File(s) | Result | Attempt | Type | Note |
|---|--------|---------|--------|---------|------|------|
| 1 | Scanned procedural/index.md | - | discovery | - | S | Found memory P009 |
| 2 | Scanned semantic/index.md | - | - | - | S | No match |
| 3 | Scanned episodic/index.md | - | - | - | S | No match |
| 4 | Read memory P009 | - | discovery | - | P | Cache invalidation pattern |
| 5 | Applied solution | cacheService.ts:45 | success | 1 | P | Works correctly |
| 6 | Updated validated + count | procedural/P009 | success | - | P | validation_count: 2 |

## Insights
Memory P009 was accurate and prevented debugging loop.

## Outcome
Memory-based solution worked on first try. Cache invalidation pattern is correct.
```

### 4. Session Log (Discovery Case)

Alternative scenario: No memory exists yet.

```markdown
---
topic: "Fix stale cached API responses"
mode: bugfix
started: 2024-01-15 14:30
status: completed
---

# Session: Fix Stale Cache After Settings Change

## Context
API returns cached data after user changes settings.

## Log
| # | Action | File(s) | Result | Attempt | Type | Note |
|---|--------|---------|--------|---------|------|------|
| 1 | Scanned all 3 type indexes | - | - | - | S | No matches found |
| 2 | Set cache TTL to 0 | cacheService.ts:30 | fail | 1 | P | Still returns stale |
| 3 | Called cache.refresh() | cacheService.ts:35 | fail | 1 | P | Only refreshes key |
| 4 | Added version param | apiClient.ts:50 | fail | 2 | P | Similar to #2 |
| 5 | **Escalation** | - | warning | - | - | Asked user (3+ attempts) |
| 6 | User suggested full clear | - | discovery | - | P | Try cache.clear() |
| 7 | Full cache clear + refetch | cacheService.ts:40-55 | success | 1 | P | Works! |
| 8 | Tested multiple scenarios | - | success | 1 | P | Stable |

## Insights
- Cache layer maintains internal state that partial invalidation does not clear
- Only full clear + refetch guarantees fresh data
- Partial invalidation methods (TTL, refresh, versioning) are unreliable
- Pattern should apply to all cache-dependent endpoints

## Outcome
Full cache clear + refetch pattern solved the issue. User insight was correct.
Root cause: Cache layer internal state management.
```

### 5. Session Complete — Multi-Type Memory Extraction

When `/myspec:session-complete` runs, agent analyzes the session log and identifies potential memories across all three types:

```
Session complete. 3 potential memories:

1. [procedural] Cache Must Be Fully Cleared for Settings Changes
   - Full clear + refetch pattern for cache invalidation
   - Triggers: cache, stale data, settings change

2. [semantic] Cache Layer Internal State Management
   - Cache layer maintains internal state that partial invalidation
     methods (TTL reset, refresh, versioning) cannot clear
   - Topic: caching, state-management, api-behavior

3. [episodic] First Cache Invalidation Bug — 2024-01-15
   - Discovered cache layer state behavior during API fix.
     User intervention required after 3 failed attempts.
   - Feature: settings

Create memories? (all / select by number / none)
```

User responds: "all"

### 6. Memory Creation — Procedural

**File: `${aiDir}/memory/procedural/P009-cache-invalidation.md`**

```markdown
---
id: P009
title: "Cache Must Be Fully Cleared for Settings Changes"
type: procedural
polarity: negative
feature: "settings"
created: 2024-01-15
validated: 2024-01-15
validation_count: 1
triggers:
  - cache
  - stale data
  - settings change
  - cached response
not_for:
  - initial load
  - cold start
  - first render
anchors:
  - file: "cacheService.ts"
    pattern: "cache.clear"
related: ["S001", "E001"]
---

# Cache Must Be Fully Cleared for Settings Changes

## Procedure (Do This)

1. Call `cache.clear(affectedKeys)` in cacheService.ts
2. Wait for flush to complete: `await cache.flush()`
3. Re-fetch affected data from API
4. **Verify**: Response contains updated values
5. **Verify**: No stale data on subsequent requests

## Why This Works

The cache layer maintains internal state beyond individual key-value pairs. Partial invalidation (TTL changes, refresh calls, version parameters) only affects the lookup path, not the underlying cached state. Full clear resets all internal state.

## What Fails (Reference Only)

DO NOT try these approaches - they will not work:

- Setting TTL to 0 → Cache still serves stale from internal buffer
- Calling cache.refresh() → Only refreshes lookup, not stored data
- Adding version/bust parameter → Bypasses key but not internal state
- Any "partial invalidation" approach → Internal state persists

## Verification

After applying procedure:
- [ ] API response reflects updated settings values
- [ ] Subsequent requests return fresh data
- [ ] No stale data appears after page navigation
```

**Updates `${aiDir}/memory/procedural/index.md`:**
```markdown
| ID | Use When | Handles | Not For |
|----|----------|---------|---------|
| P009 | cache, stale data, settings change | Cache invalidation, state reset | initial load, cold start |
```

### 7. Memory Creation — Semantic

**File: `${aiDir}/memory/semantic/S001-cache-layer-internal-state.md`**

```markdown
---
id: S001
title: "Cache Layer Internal State Management"
type: semantic
topic: caching
created: 2024-01-15
verified: 2024-01-15
source_session: "2024-01-15-cache-fix"
anchors:
  - file: "cacheService.ts"
related: ["P009", "E001"]
---

# Cache Layer Internal State Management

## Fact

The application cache layer maintains internal state beyond individual key-value entries that **cannot** be invalidated through partial methods (TTL reset, refresh calls, or version parameters).

## Implications

- Any feature that modifies user settings must use full cache clear
- This applies to: user preferences, configuration changes, role updates
- Performance cost of full clear is acceptable — cache rebuilds quickly

## Confidence

**High** — Verified through debugging session. Consistent with cache implementation internals.

## See Also

- `${aiDir}/memory/procedural/P009-cache-invalidation.md` — Specific procedure for cache clearing
```

**Updates `${aiDir}/memory/semantic/index.md`:**
```markdown
| ID | Topic | Fact | Verified | Anchor |
|----|-------|------|----------|--------|
| S001 | caching, state-management | Cache layer maintains internal state; only full clear resets it | 2024-01-15 | cacheService.ts |
```

### 8. Memory Creation — Episodic

**File: `${aiDir}/memory/episodic/E001-2024-01-15-cache-invalidation-discovery.md`**

```markdown
---
id: E001
title: "First Cache Invalidation Bug"
type: episodic
date: 2024-01-15
feature: "settings"
outcome: resolved
persistent: false
source_session: "2024-01-15-cache-fix"
related: ["P009", "S001"]
---

# E001: First Cache Invalidation Bug

## What Happened

API returned stale cached data after settings changes. Agent made 3 failed attempts (TTL reset, refresh call, version parameter) before escalating to user. User suggested full cache clear, which worked.

## Impact

- Discovered cache layer internal state behavior (now semantic memory S001)
- Created full clear + refetch procedure (now procedural memory P009)
- Established escalation protocol effectiveness — user intervention at attempt 3 was timely

## Lessons

- Cache implementation internals are not always obvious from the API surface
- "Partial invalidation" is the intuitive but wrong approach for stateful cache layers
- Escalation at 3 attempts prevented a longer debugging spiral
```

**Updates `${aiDir}/memory/episodic/index.md`:**
```markdown
| ID | Date | Event | Feature | Outcome |
|----|------|-------|---------|---------|
| E001 | 2024-01-15 | Cache invalidation bug; 3 failed attempts before user-guided fix | settings | resolved -> P009, S001 |
```

### 9. Memory Lookup — Cross-Type Search

Later, agent encounters: "User role changes don't take effect until restart"

**`/myspec:memory-lookup` scans all 3 indexes:**

```
Searching: "role, permissions, stale, cache, update"

procedural/index.md:
  P009 — "cache, stale data, settings change" — strong match

semantic/index.md:
  S001 — "caching, state-management" — strong match

episodic/index.md:
  E001 — "Cache invalidation bug" — contextual match

Loading: S001 (semantic — understanding), then P009 (procedural — action pattern)
```

Agent reads S001 first to understand the underlying cause (internal state), then adapts P009's full clear procedure for role changes. The episodic memory E001 confirms this is a known pattern area.

### 10. Session Archival

Session logs flow through:
1. **Active**: `${aiDir}/memory/sessions/active.md` (created by `/myspec:session-start`)
2. **Archive**: `${aiDir}/memory/sessions/archive/2024-01-15-cache-fix.md` (moved by `/myspec:session-complete`)

### 11. Future Usage

Next time agent sees "stale data after changes":
1. Scans `${aiDir}/memory/procedural/index.md` "Use When" column
2. Scans `${aiDir}/memory/semantic/index.md` "Topic" column
3. Scans `${aiDir}/memory/episodic/index.md` for recent related events
4. Finds keyword match in procedural: "cache", "stale data"
5. Checks "Not For" column: confirms not initial load
6. Reads full memory P009
7. Follows **Procedure** section (ignores "What Fails")
8. Verifies outcome per checklist
9. Updates `validated` date and increments `validation_count` to 2
10. **No debugging loop!**

## Layer 1 Promotion

If a procedural memory proves critical across multiple features (e.g., P009 applies to
settings, roles, and configuration), promote a one-line summary to `${aiDir}/memory/index.md`:

```markdown
## Critical Procedural (What NOT to Do)
- **P009**: Full cache clear required — never use partial invalidation for state changes
```

This ensures every agent session sees the pattern without scanning type indexes.

## Success Metrics

**Without memory system:**
- 10+ failed attempts
- 2 hours debugging
- User intervention required
- High frustration

**With memory system:**
- 1 attempt (read memory, apply solution)
- 5 minutes total
- No user intervention
- Knowledge preserved across all three memory types
