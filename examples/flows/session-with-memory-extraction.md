# Flow — session lifecycle with memory extraction

How a tracked work session is created (auto by hook, or manually), how the log accumulates, and how `/session-complete` extracts memories at the end. Compares to the on-demand `/memorify` alternative so you know which to reach for.

## The setup

You're starting a debugging session on a flaky payment-webhook test. You don't yet know if it's a quick fix or a half-day hunt. Either way, you want a record of what was tried and what worked.

## At a glance

| Step | Skill / Hook | What happens |
|------|--------------|--------------|
| 1 | `/myspec:bootstrap` | Loads project context, scans memory, picks up active sessions |
| 2 | (auto on first edit) | `mark-code-changed.sh` PostToolUse hook creates `sessions/active/{id}.md` |
| 3 | (during work) | Agent appends rows to the session log table after significant actions |
| 4 | `/myspec:session-complete` | Reviews the log, proposes memory extractions, archives the session |
| 5 | (alternative) `/myspec:memorify` | Mid-session sweep without archiving — for non-tracked or partial captures |

---

## 1. Bootstrap — orient the agent

```
/myspec:bootstrap
```

The skill walks its checklist:

- Reads `.myspec.json`, `backbone.yml`, project techStack — knows it's a Node + Postgres app.
- Reads `ai/memory/index.md` (Layer 1) — finds two pinned procedurals: "verify webhook signatures in middleware" (P017) and "no long transactions on background jobs" (P015). Notes both — they're relevant to webhook code.
- Scans `ai/memory/{procedural,semantic,episodic}/index.md` looking for keyword matches. The current task ("flaky webhook test") matches:
  - **P016** — *Create test users through the auth-service factory* (procedural)
  - **S008** — *Stripe webhook signing secret is per-environment* (semantic)
- Reads both full files since they matched.
- Lists `ai/memory/sessions/active/` — empty (no active sessions). No auto-archive needed.

The agent reports:

> Bootstrapped. Loaded 2 pinned rules and 2 task-relevant memories. No active sessions.

---

## 2. Auto-session creation on first edit

You start poking at the test and Claude runs an `Edit` tool call to add some logging. The `mark-code-changed.sh` PostToolUse hook fires and creates:

```
ai/memory/sessions/active/2026-04-30-1404-flakywebhook.md
```

with frontmatter:

```yaml
---
session_id: 2026-04-30-1404-flakywebhook
topic: "auto: webhook test investigation"
feature: ""
mode: ""
started: "2026-04-30 14:04"
status: active
auto_created: true
cwd: <repo_root>
---
```

The agent notices `auto_created: true` on its next memory pass and refines the frontmatter — `topic: "Flaky stripe webhook signature test"`, `mode: debugging`, `auto_created: false` — and writes a 1-2 sentence Context section.

> *Manual `/myspec:session-start` is only needed for non-code work (pure discovery, doc-only sessions). Otherwise the hook handles it.*

---

## 3. The log accumulates

As the work progresses, the agent appends rows to the log table inside the session file. Each row is short — timestamp, action, type hint, outcome:

```markdown
| Time  | Action | Type | Outcome |
|-------|--------|------|---------|
| 14:08 | Reproduced flake locally with `pnpm test:e2e webhook` running 20× | — | Failed 3/20 |
| 14:14 | Logged request body bytes at signature-verify boundary | S | Body length differed between pass/fail runs |
| 14:21 | Found body parser was double-decoding JSON when `Content-Type: application/json; charset=utf-8` | S 💡 | Root cause candidate |
| 14:30 | Hypothesis: charset suffix triggers second parse | — | — |
| 14:35 | Pinned signature-verify to use raw buffer; flake gone after 50× runs | P ✅ | Confirmed root cause |
| 14:40 | Wrote regression test for charset variant | — | Passing |
| 14:48 | Decided not to patch the body parser globally — risk too high | — | Tracked in ideas/ |
```

Type hints (`P` / `S`) and ✅/❌/💡 markers are signals for `/session-complete` later — they tell it what the agent already considered worth flagging.

---

## 4. Session complete — extract memories

```
/myspec:session-complete
```

The skill runs through:

**Step 1**: Picks the only active session file. Confirms target.

**Step 2**: Updates the file — `status: completed`, fills the Outcome section ("Root cause: body parser double-decoded when charset suffix present. Fix: signature verify uses raw buffer.").

**Step 3**: Analyzes the log. Sees:

- Row at 14:35 (`P ✅`) — strong procedural candidate.
- Row at 14:21 (`S 💡`) — strong semantic candidate.
- Row at 14:48 — episodic-ish but the user-facing decision is captured in `ideas/`, not load-bearing for future work.

**Step 4**: Proposes extractions:

```
Session complete. 2 potential memories:

1. [procedural] Verify webhook signatures against the raw request buffer
   — JSON-parsed bodies fail signature checks when charset suffix is
   present.
2. [semantic] Express body-parser double-decodes when Content-Type
   carries `; charset=utf-8` and the body is JSON.

Reply with numbers to extract (e.g. "1 and 2"), "all", or "none".
```

User: `all`.

**Step 5**: For each, asks one clarifying question, drafts the file (with `source_session: 2026-04-30-1404-flakywebhook` in the frontmatter), shows it, gets approval, writes.

**Step 6**: Archives the session — moves the file from `active/` to `archive/2026-04/`. Appends a one-line summary to `ai/memory/sessions/index.md`.

Final tally:

> Session archived. Saved 2 memories: P018, S009.

---

## 5. The `/memorify` alternative

What if you didn't want to archive the session yet — maybe the work is paused but not done? Or what if no session was ever created (e.g., you were exploring, never edited code, no hook fired)?

Run `/memorify` instead. It scans the conversation directly, **doesn't touch the session log**, and just produces memories. See:

- [memorify-single-candidate.md](../memorify-single-candidate.md)
- [memorify-multi-candidate.md](../memorify-multi-candidate.md)

The trade-off:

| | `/session-complete` | `/memorify` |
|---|---|---|
| Requires active session | yes | no |
| Archives session | yes | no |
| Source material | session log table | recent conversation turns |
| Cross-links memories with `source_session` | yes | only if session is active |
| Use when | wrapping up a tracked work block | grabbing a memory mid-flight, or no session ever existed |

---

## What this flow demonstrates

- **Sessions are mostly automatic.** The hook does the boring part. Agents only need to refine the auto-created file's frontmatter.
- **The log table is the source of truth for `/session-complete`** — type hints (`P`/`S`) and outcome markers (✅/❌/💡) make extraction reliable.
- **`source_session` links the memory back to where it came from**, so a future agent investigating the same memory can pull up the full session context.
- **Archive on completion**: completed sessions move to `archive/{YYYY-MM}/`. The active dir stays clean, which is what `bootstrap` and `feature-implement` rely on for their "is anything in flight?" checks.
- **`/memorify` and `/session-complete` are siblings**, not duplicates. Different inputs, different side effects.
