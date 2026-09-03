# `/myspec:session-complete` — examples

Wraps a tracked work session: marks the session log `completed`, reviews the log table for memory candidates, proposes extractions, and archives the session file. Pairs with the `mark-code-changed.sh` hook that auto-creates active sessions on first code edit.

> **Related**: For the full session-tracking lifecycle (auto-create → log → archive), see [flows/session-with-memory-extraction.md](../flows/session-with-memory-extraction.md). The scenarios here focus on the wrap-up step itself.

**Contents**

- [Multiple memories extracted with cross-links](#multiple-memories-extracted-with-cross-links)
- [Nothing extractable — all in the diff](#nothing-extractable--all-in-the-diff)
- [Multiple active sessions — confirm target first](#multiple-active-sessions--confirm-target-first)

---

## Multiple memories extracted with cross-links

The high-yield case: a productive session left typed log entries (P / S markers) that translate cleanly into memories.

### Setup

The user just finished a 90-minute session debugging and fixing a bug in the OAuth callback flow. The session log accumulated:

```
| Time  | Action | Type | Outcome |
|-------|--------|------|---------|
| 14:00 | Reproduced 401 on /auth/callback after sign-in | — | confirmed |
| 14:08 | Found OAuth state cookie was httpOnly but redirect uses location.replace | S 💡 | root cause candidate |
| 14:14 | Verified: SameSite=Lax cookies don't survive cross-site redirect from provider | S 💡 | confirmed |
| 14:20 | Fix: change state cookie to SameSite=None; Secure | P ✅ | works |
| 14:35 | Decided not to use SameSite=Strict — would block legitimate cross-domain link clicks | — | scope decision |
| 14:50 | Wrote regression test + verified across Chrome/Firefox/Safari | — | passed |
```

Session frontmatter `status: active`, topic `OAuth callback 401`.

### Invocation

```
/myspec:session-complete
```

### Skill flow

#### 1. Identify target

One active session — uses it. Refines the topic if needed.

#### 2. Update session log

Sets `status: completed`. Fills the **Outcome** section:

> Worked: changed OAuth state cookie to `SameSite=None; Secure`. The previous `SameSite=Lax` blocked the cookie from surviving the cross-site redirect from the OAuth provider.
>
> Root cause: `SameSite=Lax` is more restrictive than its name suggests — it blocks cookies on cross-site POST/redirect even when the user is just navigating back to our site.
>
> Insights: `SameSite` values have non-obvious semantics; Strict and Lax both have surprising failure modes. Always test with real cross-site redirects, not just local emulation.

#### 3. Analyze for extractions

Reads the log table:

- Two `S 💡` entries (rows at 14:08, 14:14) — same topic, candidate for one combined semantic memory.
- One `P ✅` entry (row at 14:20) — candidate for procedural memory.
- The 14:35 row (scope decision) — borderline episodic; user signaled the *why* but it's not a long-lasting decision (it was a one-time scope call). Skipped.

#### 4. Propose extractions

```
Session complete. 2 potential memories:

1. [procedural] Use SameSite=None; Secure on cookies that need to survive
   cross-site OAuth redirects.

2. [semantic] SameSite=Lax blocks cookies on cross-site POST/redirect even
   when navigating back to our origin — its name implies it's permissive,
   but it's surprisingly strict.

Reply with numbers ("1 and 2"), "all", or "none".
```

User: `all`.

#### 5. Per-extraction clarifying questions + drafts

**Memory 1 (procedural)**:

> "Any case where SameSite=Lax is still the right choice for OAuth-related cookies? E.g., session cookies that don't cross sites?"

User: *"Yes — regular session cookies stay Lax, this rule is specifically for OAuth state cookies that need to survive provider round-trips."*

Skill claims `P020` via `.claude/lib/memory-claim-id.sh procedural` and drafts `P020-oauth-state-cookie-samesite.md` with explicit `not_for: [regular session cookies, cookies not used in OAuth flow]`.

**Memory 2 (semantic)**:

> "Is there a config or test file that demonstrates this in our codebase, so a future check can verify it?"

User: *"`src/auth/cookies.ts` — the `OAUTH_STATE_COOKIE_OPTIONS` constant."*

Skill claims `S009` (`memory-claim-id.sh semantic`) and drafts `S009-samesite-lax-cross-site-behavior.md` with anchor.

Both drafts include `source_session: 2026-04-30-1400-oauthcallback`.

User approves both.

#### 6. Cross-linking

After both are written, the skill edits each file's `related:` field — `P020.related: [S009]`, `S009.related: [P020]`. Same conversation, paired memories.

#### 7. Archive

Moves `.claude/state/sessions/2026-04-30-1400-oauthcallback.md` → `ai/memory/sessions/archive/2026-04/2026-04-30-1400-oauthcallback.md`. Appends a one-line summary to `ai/memory/sessions/index.md`:

```markdown
| 2026-04-30 | OAuth callback 401 | OAuth state cookie SameSite mismatch | P020, S009 |
```

#### 8. Reports tally

> Session archived. Saved 2 memories: P020, S009. Cross-linked.

### Why this example matters

- **Type hints in the log are the secret sauce.** `S 💡` and `P ✅` aren't decorative — they're how `session-complete` knows which rows are extraction candidates without re-reading the conversation. Disciplined log-table maintenance pays back here.
- **Combining adjacent rows.** Two `S 💡` entries about the same topic became one memory, not two. The skill recognizes adjacency; the user wouldn't want `S009` and `S010` saying the same thing differently.
- **`source_session` is forward-looking.** A future agent investigating P020 can pull up the full session log to see *how* the rule was discovered. That context is gone if you only have the rule itself.
- **Skipped extraction is also OK.** The 14:35 "scope decision" row was borderline; the skill chose not to propose it. Forcing every typed row into a memory produces noise.

---

## Nothing extractable — all in the diff

Sometimes a session was productive code-wise but had no memory-worthy insights. The skill says so and still archives.

### Setup

The user spent the session implementing the next 3 tasks of an `/feature-implement` plan — straightforward dispatches, no surprises. Session log table has 12 rows, all `[~]→[x]` task transitions and standard test-pass markers. Zero `💡` entries.

### Invocation

```
/myspec:session-complete
```

### Skill flow

#### Steps 1–2

Standard. `status: completed`. Outcome filled in: "Completed tasks T4, T5, T6 of the scheduled-reports plan. Tests pass. No surprises."

#### Step 3 — analyze for extractions

Reviews the log table. No `S 💡`, no `P ✅` markers, no decision rows. Every row is mechanical task progress.

#### Step 4 — report no candidates

```
Session complete. No memories worth extracting from this session — the
work was straightforward implementation following an approved plan.
The diff captures everything reusable.
```

#### Step 6 — archive

Moves the session to the archive without writing any memories. Index entry:

```markdown
| 2026-04-30 | scheduled-reports T4-T6 | Plan execution, no surprises | (none) |
```

### Why this example matters

- **No-memory archive is normal and healthy.** Most plan-execution sessions look like this. Forcing memories from them dilutes the memory system.
- **The session log is preserved regardless.** Even when no memories are extracted, the log itself is archived — useful for "what was happening on this branch on this day" archaeology later.

---

## Multiple active sessions — confirm target first

Multi-agent workflows (e.g., parallel `feature-implement` subagents) can leave several active sessions. The skill picks the most likely target but asks the user to confirm.

### Setup

The user ran a parallel-group phase of `feature-implement` earlier. Each parallel subagent (3 agents in worktrees) created its own session log via the hook. The user is wrapping up.

`.claude/state/sessions/` contains:

- `2026-04-30-0900-orchestrator.md` (started 1h ago, mtime 5 min ago — main agent, just finished phase review)
- `2026-04-30-0905-T2.md` (started 55 min ago, mtime 30 min ago — completed parallel task)
- `2026-04-30-0905-T3.md` (started 55 min ago, mtime 32 min ago — completed parallel task)

### Invocation

```
/myspec:session-complete
```

### Skill flow

#### 1. Identify target — multiple active

The skill detects 3 active sessions. Picks the latest mtime (orchestrator) as most likely, but presents the list:

```
Multiple active sessions detected:

  1. 2026-04-30-0900-orchestrator.md (last activity: 5 min ago) [most recent]
     topic: scheduled-reports phase 4 dispatch
  2. 2026-04-30-0905-T2.md (last activity: 30 min ago)
     topic: ScheduleRepository
  3. 2026-04-30-0905-T3.md (last activity: 32 min ago)
     topic: ExportRunRepository

I'll target #1 (orchestrator) by default. The other two are completed
parallel-task sessions from worktree subagents — they should also be
closed eventually, but I'll only touch what you confirm.

Reply with numbers (e.g. "1 and 2 and 3" or "all") to specify which
sessions to complete in this run, or "1" to target only the orchestrator.
```

User: `all`.

#### 2–6 (per session)

The skill processes each session independently, in order: T2, T3, then orchestrator. For each: updates frontmatter, fills outcome, analyzes for extractions, proposes per session.

- T2's session log has one `S 💡` row (a discovery about `pg-driver` parameter binding) → one memory candidate.
- T3's session log has nothing memory-worthy.
- Orchestrator's log has a `P ✅` row about phase-review checklist refinement → one memory candidate.

User accepts both candidates.

#### 7. Archive all three

Each session moves to `ai/memory/sessions/archive/2026-04/`. Index gets three rows. Two memories written.

### Why this example matters

- **Multi-active is normal in modern workflows.** Subagents in worktrees create sibling sessions; the orchestrator has its own. The skill doesn't panic — it confirms scope.
- **Per-session extraction.** Each session's log is reviewed independently. The orchestrator's "phase review went well" insight is different from T2's "parameter binding gotcha" — they're genuinely separate memories.
- **Defensive default — pick the most recent, ask before touching siblings.** If the user types `1`, the skill closes only the orchestrator. The subagent sessions stay active until explicitly closed. This prevents accidental archive of sessions other agents may still be writing to.
