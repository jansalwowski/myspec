---
title: "Agent Memory System"
purpose: "Overview and quick reference for the type-aware memory architecture"
updated: 2026-03-24
---

# Agent Memory System

**Preserves knowledge across sessions using typed memories and context layering.**

## Quick Links

- **Agent behavior**: `.claude/rules/memory-system.md`
- **Global Index (Layer 1)**: `${aiDir}/memory/index.md`
- **Procedural Index**: `${aiDir}/memory/procedural/index.md`
- **Semantic Index**: `${aiDir}/memory/semantic/index.md`
- **Episodic Index**: `${aiDir}/memory/episodic/index.md`
- **Live Sessions**: `.claude/state/sessions/{session_id}.md` (gitignored, primary checkout; per-agent, auto-created on first code edit)
- **Templates**: `${aiDir}/.templates/memory-{procedural,semantic,episodic}.md`

## File Structure

```
${aiDir}/memory/
├── index.md                    # Layer 1 (always loaded)
├── procedural/
│   ├── index.md
│   └── P{NNN}-{slug}.md
├── semantic/
│   ├── index.md
│   └── S{NNN}-{slug}.md
├── episodic/
│   ├── index.md
│   └── E{NNN}-{slug}.md
└── sessions/
    ├── active/
    │   └── {session_id}.md      # one per agent run with code edits
    └── archive/
```

## Four Memory Types

### 1. Working Memory — Active Session Log

**Purpose**: Track in-progress work, survive context clears, detect loops.

- Auto-created on first code edit by `mark-code-changed.sh` at `.claude/state/sessions/{session_id}.md`; every code path is appended to `## Files touched`, which is how a skill recognises its own session
- Per-session-id keying makes this multi-agent safe — each agent gets its own file
- Manual `/myspec:session-start` only needed for non-code sessions (debugging without edits, discovery, doc-only)
- Logs each significant action with result and attempt count
- Triggers escalation when patterns repeat
- Archived to `${aiDir}/memory/sessions/archive/` by `/myspec:session-complete`; orphans (> 6h stale) auto-archived by `/myspec:bootstrap`, 1–6h ones only reported

### 2. Procedural Memory — Patterns and Anti-Patterns

**Purpose**: Encode how-to knowledge — what works, what fails, and why.

- **ID prefix**: `P{NNN}`
- **Triggers**: Specific symptoms or situations that activate the memory
- **Content**: Procedure (Do This) → Why This Works → What Fails → Verification
- **When to create**: After resolving tricky bugs, discovering non-obvious patterns, or when user provides key insights
- **Examples**: "Always use the project logger, not console.log", "Database transaction pattern requires optional client parameter"

### 3. Semantic Memory — Codebase Facts

**Purpose**: Record factual knowledge about the codebase that accumulates over time.

- **ID prefix**: `S{NNN}`
- **Content**: Architecture decisions, dependency relationships, configuration facts, naming conventions
- **When to create**: After discovering codebase structure, mapping dependencies, or learning non-obvious facts about the system
- **Examples**: "Auth service uses session cookies, not JWT tokens", "GraphQL schema uses code-first builder pattern"

### 4. Episodic Memory — Significant Events

**Purpose**: Record notable events and their outcomes for future reference.

- **ID prefix**: `E{NNN}`
- **Content**: What happened, context, outcome, lessons learned
- **When to create**: After significant debugging sessions, major refactors, production incidents, or architectural changes
- **Consolidation**: Episodic memories consolidate into semantic facts after 30 days
- **Mechanism**: `/myspec:memory-preflight` flags episodes > 30 days old for consolidation during pre-flight checks
- **Examples**: "2024-03-15: Migrated auth from JWT to session cookies — broke API clients until CORS updated"

## Context Layering

| Layer | When Loaded | Budget | Location |
|-------|-------------|--------|----------|
| **Layer 1** | Always | ~200 tokens | `${aiDir}/memory/index.md` |
| **Layer 2** | Task-specific | ~500 tokens per index | `${aiDir}/memory/{procedural,semantic,episodic}/index.md` |
| **Layer 3** | On demand | Unlimited | `${aiDir}/memory/sessions/archive/`, individual memory files |

**Layer 1** contains critical anti-patterns and a summary of what exists in each type index. Every agent session reads this first.

**Layer 2** indexes are loaded based on the task at hand. Procedural index for debugging, semantic index for architecture questions, episodic index for understanding history.

**Layer 3** includes full memory files and archived sessions, loaded only when a specific memory is relevant.

## Workflows

### Starting Work

```
1. Read ${aiDir}/memory/index.md (Layer 1 — always)
2. Read type-specific indexes based on task:
   - Procedural: ${aiDir}/memory/procedural/index.md (debugging, implementation)
   - Semantic: ${aiDir}/memory/semantic/index.md (architecture, structure)
   - Episodic: ${aiDir}/memory/episodic/index.md (history, context)
3. Check for existing active sessions (resume own, leave siblings alone)
4. Session file at .claude/state/sessions/{session_id}.md (auto-created on first code edit)
```

**Tiered approach:**
- **Full preflight** (`/myspec:memory-preflight`): New features, multi-file changes, debugging sessions
- **Quick check** (read Layer 1 only): Single-file fixes, typos, config changes, documentation updates

### During Work

```
After each action → Log in session table
On error → Scan procedural index for matching triggers
On architecture question → Check semantic index
On repeated failure → Check escalation triggers
```

### Escalation Triggers (MUST pause)

- Same file edited 3+ times without success
- Same error after 2+ different fixes
- About to try previously-failed approach
- Adding workarounds without understanding
- User corrected approach 2+ times

### Completing Work

```
1. Update active session status: completed
2. Fill Outcome section
3. Multi-type extraction — ask user:
   - Procedural: "Any patterns or anti-patterns to save?"
   - Semantic: "Any codebase facts discovered?"
   - Episodic: "Was this event significant enough to record?"
4. Create memories in appropriate type directories
5. Archive session to ${aiDir}/memory/sessions/archive/YYYY-MM-DD-slug.md
```

### Memory Skills

| Phase | Skill | Purpose |
|-------|-------|---------|
| Before work | `/myspec:memory-preflight` | Read Layer 1 + relevant type indexes |
| Start session | `/myspec:session-start` | Create active session log |
| During work | `/myspec:memory-lookup` | Search across all memory types |
| End session | `/myspec:session-complete` | Archive + multi-type extraction prompt |
| Create memory | `/myspec:memory-create` | Create typed memory in correct directory |

### Tooling (`.claude/lib/`)

| Script | Purpose |
|--------|---------|
| `memory-claim-id.sh <type>` | Allocates the next ID: conformance check, lock on the main checkout, scan of every worktree and every branch, registry in `.claude/state/`. Exit 3 = refused on conformance errors |
| `memory-index.mjs [--check\|--backfill\|--dry-run]` | Regenerates the three index tables from the files (`| ID | Hook | Anchor |`); refuses while a memory lacks `hook:` (`--backfill` derives it from the row or heading) |
| `memory-doctor.mjs [--quiet\|--json]` | Reports what disagrees with the tooling: filename case, missing `hook:`, duplicate IDs across branches, malformed anchors, an unignored `.claude/state/` |
| `memory-files.mjs` | Shared parser the two scripts above import — the single definition of "a memory file" (case-insensitive, slug-optional, every anchor form) |

Filenames are `{ID}-{slug}.md` with an uppercase prefix. The tooling reads lowercase and slugless names too, but the doctor flags them.

## Implementation Status

### Phase 1: Core Files — COMPLETE

- [x] Agent behavior rules in `.claude/rules/memory-system.md`
- [x] Templates in `${aiDir}/.templates/`
- [x] Session directory structure
- [x] Memory system documentation

### Phase 2: Type-Aware Architecture — COMPLETE

- [x] Three memory type directories (procedural, semantic, episodic)
- [x] Type-specific index files
- [x] Layer 1 global index at `${aiDir}/memory/index.md`
- [x] Context layering system
- [x] Multi-type extraction workflow
- [x] Type-specific templates

## Success Metrics

System works if:

1. Agent checks all three type indexes before work (not just anti-patterns)
2. Sessions capture non-debugging knowledge (discovery, implementation modes used)
3. Multi-type extractions happen at session-complete
4. Semantic facts accumulate over time (not just procedural fixes)
5. Stale memories are flagged and resolved during pre-flight
6. Episodic memories consolidate into semantic facts after 30 days
7. Cross-feature knowledge is findable without being in anti-patterns

## Integration Points

### With Existing Rules

- Memory system **supplements** existing workflows
- Still follow project-specific rules and conventions
- Adds **learning, knowledge retention, and loop prevention** layer

### With Task Routing

- "Any work" starts with Layer 1 index + relevant type indexes
- "Debugging loop" triggers procedural memory check + session log
- See project CLAUDE.md task routing table
