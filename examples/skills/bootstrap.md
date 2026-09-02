# `/myspec:bootstrap` — examples

Loads project context, scans memory indexes for task-relevant entries, and checks for active sessions. Run once at the start of a work session before making changes. **Don't run it mid-task** — it's an orient-yourself skill, not a refresh.

**Contents**

- [Standard bootstrap with task-relevant memory pickup](#standard-bootstrap-with-task-relevant-memory-pickup)
- [Stale active session — auto-archive triggers](#stale-active-session--auto-archive-triggers)
- [Fresh project — no memories yet](#fresh-project--no-memories-yet)

---

## Standard bootstrap with task-relevant memory pickup

The everyday case: a working project with a few months of memories, the user starts a session with a clear task in mind.

### Setup

The user opens a new Claude session in a project they've worked on for months. Memory has accumulated. The user types a goal first:

> *"I'm going to work on adding a CSV import to the user-invitations feature."*

Then runs:

```
/myspec:bootstrap
```

### Skill flow

#### 1. Read project config

Reads `.myspec.json`. Project name "Acme Reports", techStack "Node 20 + Postgres 15 + React 19". `aiDir: ai`. `topologyFile: backbone.yml`.

Reads `backbone.yml`: identifies the relevant area for "user-invitations" (the `apps/web` and `apps/api` zones), notes the protected path `infra/secrets/` (don't modify), notes available commands (`pnpm dev`, `pnpm test`, `pnpm typecheck`).

#### 2. Read Layer 1 memory index

Reads `${aiDir}/memory/index.md`:

- **Pinned rules** — three entries. Two are universal (always apply). One is **P017** *Verify webhook signatures in middleware* — task-irrelevant but already loaded by virtue of being pinned.
- **Must-Know Facts** — the marketing-static-only decision (E009), the 50-byte Redis key cap (S007).
- **Recent Significant Events** — last 30 days. The webhook-signature-bug episode (E010), the marketing-SSR-removal (E009).

All three pinned rules will apply throughout the session.

#### 3. Scan Layer 2 indexes — a task was given

The invocation carried a task, so the Layer 2 scan runs. Task: "CSV import to user-invitations feature." Keywords: `invitations`, `csv`, `import`, `bulk`, `email`.

- **Procedural index**: `P017` (already loaded — pinned). `P022` *Admin-only routes use requireAdmin middleware* — `Hook: admin route, permission, role` — possibly relevant if the bulk-import endpoint is admin-only. Loaded.
- **Semantic index**: `S008` *Stripe webhook signing secret per-environment* — no match. Skipped.
- **Episodic index**: nothing about invitations specifically.

#### 4. Check for active sessions

Lists `${aiDir}/memory/sessions/active/`. One file: `2026-04-30-1027-uierror.md` with mtime 8 minutes ago. Well inside the live window (< 1 hour — sessions over 6 hours stale get auto-archived as `abandoned`; 1–6 hours only gets reported with a `/myspec:session-clean` suggestion). Auto-created by the hook.

The skill notes:

> Active session detected: `2026-04-30-1027-uierror.md` (auto-created 8 min ago). Topic still says "auto: ...". When you start the new task, I'll either refine that session's frontmatter or — if it's truly a different topic — close it via `/myspec:session-complete` first.

#### 5. Check worktrees and framework version

`git worktree list` shows only the main checkout — worktree health clean, line omitted from the summary. `.myspec.json` `frameworkVersion` matches the plugin manifest — version line omitted too. (A stale worktree would surface a `worktree-cleanup` warning; a version gap would surface a `/myspec:update` prompt.)

#### 6. Reports back

> **Project context loaded**
>
> Acme Reports — Node 20 / Postgres 15 / React 19. Working areas: `apps/web`, `apps/api`. Don't touch `infra/secrets/`.
>
> **Pinned rules in effect (3)**
>
> - P017 — Verify webhook signatures in middleware
> - E009 — Marketing site is static; don't reintroduce SSR
> - S007 — Redis keys must stay under 512 bytes
>
> **Task-relevant memory**
>
> - P022 — Admin-only routes use `requireAdmin` middleware (likely applies to bulk-import endpoint)
>
> **Active session**
>
> - One auto-created session from 8 min ago — looks like leftover from a quick UI fix. Either refine or close before starting the invitations work.
>
> Ready to work on CSV import for user-invitations.

### Why this example matters

- **Bootstrap is selective, not exhaustive.** Three pinned rules + one task-relevant procedural is right — loading every memory would drown signal in noise. The keyword match is what filters.
- **Topology file matters.** Knowing the protected paths *before* starting work prevents accidents like Claude editing a secrets template.
- **Active-session detection is part of bootstrap, not a separate step.** Sessions left around from interrupted work need acknowledgment before the new task — otherwise the new work pollutes the old session log.
- **The agent notes the session staleness check.** "Topic still says auto:" is a clue that the previous work didn't finish properly. User decides whether to close it.

---

## Stale active session — auto-archive triggers

A session was left active for hours when the user closed their laptop. Bootstrap notices and auto-archives.

### Setup

The user opens Claude after a few days off. Their last session ended with their laptop closing — the session log was never archived.

```
/myspec:bootstrap
```

### Skill flow

Steps 1–3 proceed normally.

#### 4. Active session check — stale detection

Lists active sessions. One file: `2026-04-26-1530-checkoutbug.md`, mtime: 4 days ago.

Auto-archive policy: >60 minutes stale = orphaned. 4 days is well beyond.

The skill auto-archives:

```
Detected stale active session (4 days old, no activity). Auto-archiving:

  ai/memory/sessions/active/2026-04-26-1530-checkoutbug.md
    → ai/memory/sessions/archive/2026-04/2026-04-26-1530-checkoutbug.md

  Frontmatter updated: status: orphaned, archived_at: 2026-04-30
  Note added: "Auto-archived during bootstrap — agent stopped without
              running session-complete. Outcome section may be empty."
```

The session is moved without losing its log table — a future agent investigating that period can still read what was tried.

#### 5. Bootstrap continues

Reports back:

> Cleaned up 1 stale session (auto-archived as orphaned). Otherwise: project context loaded as usual.

### Why this example matters

- **Auto-archive prevents accumulation.** Without it, the active sessions directory accumulates ghosts; future bootstrap calls get noisier; multiple-active-session warnings start firing.
- **Orphaned ≠ deleted.** The session file lives in the archive with full log preserved, just marked as `orphaned` so future searches know it didn't end cleanly.
- **The 60-minute threshold is the right floor.** Shorter would archive sessions during a normal lunch break; longer would let real orphans pile up.

---

## Fresh project — no memories yet

The first session on a project that just ran `/myspec:init`. Bootstrap is mostly empty but useful — it confirms the project structure and tells the user what's not there.

### Setup

User just ran `/myspec:init` an hour ago, set up the basic scaffolding, and now starts their first real coding session.

```
/myspec:bootstrap
```

### Skill flow

#### 1–3. Project + memory scans

- `.myspec.json` exists, `aiDir: .ai`. Topology file: none yet (skill notes this).
- `${aiDir}/memory/index.md`: present, but contents are the template defaults — no actual entries.
- Procedural / semantic / episodic indexes: empty (no rows).
- Pinned rules: zero.

#### 4. Active sessions

`${aiDir}/memory/sessions/active/` exists but contains only `.gitkeep`. No active sessions.

#### 5. Reports back

> **Project context loaded**
>
> Acme Reports — newly initialized. `.myspec.json` configured, `${aiDir}/` scaffolded.
>
> **No memories yet.** This is normal — the system is empty until you start capturing things.
>
> **No active sessions.**
>
> **Recommendations for a fresh project**
>
> - Consider adding a topology file (`backbone.yml` or similar) so future bootstraps know which areas are protected and what the dev/test/lint commands are. `/myspec:setup backbone` can scaffold one.
> - As you work, run `/myspec:memorify` at the end of any session that involved corrections, surprises, or decisions. The first 5–10 memories are the highest-leverage — they cover the project's main quirks.
> - When you implement your first feature, use the spec→tech-spec→plan→implement flow rather than going straight to code. The early features set the template for how the team uses the framework.
>
> Ready to start work.

### Why this example matters

- **Empty is OK.** The skill doesn't pretend a fresh project has hidden memories — it confirms the absence honestly.
- **Recommendations come with the empty state.** A new user benefits from the "what to do next" — the skill earns its keep even when it has no memory to surface.
- **Topology file gap is named.** Without `backbone.yml` (or equivalent), bootstrap is missing a layer of project context. The skill flags this and routes to `/myspec:setup backbone`.

## Session start with no task — Layer 2 deferred

The common case: a session opens with `/myspec:bootstrap` and nothing else. There is no task
to match memory against yet.

### Setup

```
/myspec:bootstrap
```

A mature project: 58 procedural, 83 semantic, 8 episodic entries. Layer 1 (`index.md`) still
holds only its template comments — nothing was ever promoted into it.

### Skill flow

#### 2. Layer 1 loads

`${aiDir}/memory/index.md` read as always. No entries — only the template's section comments.

#### 3. Layer 2 counted, not read

No task, so no keywords, so a scan could only ever report "none". The three index tables are
counted instead of read:

```
procedural: 58
semantic: 83
episodic: 8
```

#### 4–6. Reports back

> **Project context loaded**
>
> Sporticos Frontend — Nuxt 3 SSR. Working areas: `server/api/`, `pages/`, `config/cache.js`.
>
> **Memory**: Layer 1 empty | Layer 2 available: 58 procedural, 83 semantic, 8 episodic — not
> scanned, no task yet. I'll run `/myspec:memory-preflight` once you tell me what we're working on.
>
> **Layer 1 is empty** while Layer 2 holds 149 entries — the always-loaded layer is returning
> nothing for its slot. Worth promoting the handful you'd want in front of every session.
>
> **No active sessions.**
>
> Ready — what are we working on?

### Why this example matters

- **A scan with no keywords is not a cheap scan.** It reads the largest tables in the skill to
  conclude "none". Those tables grow about a row per session, so the waste compounds.
- **Deferral is not skipping.** The scan still happens — at `/myspec:memory-preflight`, once
  there is something to match against. The Layer 1/Layer 2 split exists precisely for this.
- **The empty Layer 1 gets named.** Otherwise the project keeps paying for a layer that
  returns nothing, and nobody notices.
