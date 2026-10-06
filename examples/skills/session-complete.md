# `/myspec:session-complete` — examples

Wraps a tracked work session: marks the session log `completed`, reviews the log table for memory candidates, proposes extractions, and archives the session file. Pairs with the `mark-code-changed.sh` hook that auto-creates active sessions on first code edit.

> **Related**: For the full session-tracking lifecycle (auto-create → log → archive), see [flows/session-with-memory-extraction.md](../flows/session-with-memory-extraction.md). The scenarios here focus on the wrap-up step itself.

**Contents**

- [Multiple memories extracted with cross-links](#multiple-memories-extracted-with-cross-links)
- [Nothing extractable — all in the diff](#nothing-extractable--all-in-the-diff)
- [Multiple active sessions — confirm target first](#multiple-active-sessions--confirm-target-first)
- [Friction report — whose side is the problem on](#friction-report--whose-side-is-the-problem-on)

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

Skill claims `P020` via `"${CLAUDE_PLUGIN_ROOT}/lib/memory-claim-id.sh" procedural` and drafts `P020-oauth-state-cookie-samesite.md` with explicit `not_for: [regular session cookies, cookies not used in OAuth flow]`.

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

Two top-level sessions in one checkout leave two active logs. Subagents do not add a third: they share their parent's session id, so their edits land in the parent's log, tagged. The skill picks its own file by the paths it edited and asks before touching the other.

### Setup

The user ran a parallel-group phase of `feature-implement` (two implementer subagents in worktrees) and, in a second terminal, a separate session fixing a flaky test. Both are still open.

`.claude/state/sessions/` contains:

- `5f2c9a1e….md` (started 1h ago, mtime 5 min ago). Its `## Files touched`:

  ```
  - `src/reports/index.ts`
  - `.claude/worktrees/t2/src/reports/schedule-repository.ts` (subagent a6baef07, general-purpose)
  - `.claude/worktrees/t3/src/reports/export-run-repository.ts` (subagent c91d0e44, general-purpose)
  ```

- `b7e3d210….md` (started 40 min ago, mtime 20 min ago). Its `## Files touched` lists `tests/reports/retry.test.ts`.

### Invocation

```
/myspec:session-complete
```

### Skill flow

#### 1. Identify target — multiple active

The controller wired `src/reports/index.ts` itself, and that path is untagged in `5f2c9a1e….md`. The two tagged lines carry the agent ids its Agent tool reported for T2 and T3, which confirms the match. `b7e3d210….md` lists nothing it edited.

```
Multiple active sessions detected:

  1. 5f2c9a1e… (last activity: 5 min ago) [yours: lists your edits]
     topic: scheduled-reports phase 4 dispatch
  2. b7e3d210… (last activity: 20 min ago)
     topic: auto:reports

I'll complete #1 only. #2 belongs to another session; /myspec:session-clean
handles it once it goes stale.
```

#### 2–6

The Outcome credits the two repository files to T2 and T3 as delegated work, and the `index.ts` wiring to the controller. T2's report mentioned a `pg-driver` parameter-binding gotcha, which becomes one memory candidate.

#### 7. Archive

Only `5f2c9a1e….md` moves to the archive. `b7e3d210….md` is left as it was.

### Why this example matters

- **One log per top-level session.** Before #225 the docs said each subagent created its own log; a capture showed subagents share the parent's `session_id`, so their paths always landed in the parent's file, indistinguishable from the controller's.
- **Tags keep ownership exact.** An untagged line is the main session's edit; a tagged line is a subagent's, attributed to it. A subagent never completes the session it ran in.
- **Defensive default.** The other top-level session is never touched; that is `/myspec:session-clean`'s job.

---

## Friction report — whose side is the problem on

A session that felt slow. The user wants to know whether to fix something in their project or file a myspec issue. Step 7 answers from the transcripts, with no model tokens spent.

### Setup

A `feature-implement` run on the invoices feature took most of the afternoon. During it:

- The Stop hook blocked four times on the same memory conformance error before the agent fixed the duplicate ID.
- One implementer returned `**Status:** NEEDS_CONTEXT` because the spec did not say which role may void an invoice.
- The project's test suite failed once and was fixed.
- The isolation prompt fired once, on the first edit.

### Skill flow

#### Steps 1–6

Standard. The archived log's frontmatter has `session_id: 9f3c2a71-…`. The session was resumed once after a restart, so step 1 also matched a second log, `session_id: 4b7e10d2-…`, by the paths it lists.

#### Step 7 — friction report

```bash
node "${CLAUDE_PLUGIN_ROOT}/lib/friction-scan/scan.mjs" --session=9f3c2a71-…,4b7e10d2-…
```

```
friction-scan: session 9f3c2a71, 2h05m active, 11 subagents

| Pattern | Owner | Count | Ref | Detail |
|---|---|---|---|---|
| hook block: memory-conformance | myspec | 4 | hooks/verify-before-stop.sh | Memory conformance check failed for changes under ai/memory. Fix these before stopping (… |
| subagent-needs-context | project | 1 | - | Implement Task 4 |

Slowest subagents: Implement Task 3 (24m); Phase 2 review (11m); Implement Task 4 (9m)

1 row(s) look framework-side (owner myspec).
```

The skill shows the table as printed and does not re-argue the owners.

#### Step 8 — confirm

> Session archived. No memories extracted. Friction: 1 myspec row (memory conformance blocked 4 times), 1 project row (Task 4 needed a spec answer).

### Why this example matters

- **Single events are not friction.** The one isolation prompt and the one test failure are absent: a hook doing its job once, and a project check the agent fixed, are normal. Only the repeat is reported.
- **`NEEDS_CONTEXT` points at the project by default.** The implementer asks for context when the spec or plan did not provide it, so the fix is usually a spec edit, not a framework change.
- **`unknown` is an answer.** A row the rules cannot attribute stays `unknown`. The skill does not guess, because a confident wrong owner sends the user to the wrong repo.
- **A resumed session is one run.** The work after the restart ran under a new id. Passing only the archived log's id left everything after the restart unscanned (#170); the scan takes every id and counts repeats across them.
- **Opting out** is `"feedback": { "frictionReport": false }` in `.myspec.json`.
