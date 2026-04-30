---
name: "memorify"
description: "Use when the user asks to scan the current conversation for things worth remembering — phrasings like 'memorify this', 'anything to remember from this?', 'save what we learned'. Yields zero, one, or many memories; memory-type vocabulary stays internal. Do NOT use when the exact content is already named (use /memorize), when wrapping a tracked session (use /session-complete), or for trivial config visible in code."
---

# Memorify

Conversation-wide sweep: look back at what was just discussed, surface anything worth remembering, ask the user plain questions to firm it up, then write each approved memory.

## Constraints

- **Never expose memory-type terminology to the user.** Words like "procedural", "semantic", "episodic", "anchor", "polarity" must not appear in any user-facing message. Classify silently.
- A single `/memorify` run can produce **0, 1, or many** memories. Don't force a memory if nothing of value emerges — say so and stop.
- Each candidate gets its own draft + confirmation cycle. The user can accept, edit, or skip individually.
- Index entries contain keywords/topics ONLY — never the rule, fact, or narrative body.
- Use the conversation as raw material — don't invent facts the user didn't actually say or do.

## Workflow

### 1. Sweep the Conversation for Candidates

Re-read the recent turns (current task, decisions, corrections, surprises, hand-rolled fixes). Look for items in **any** of these categories:

- **Reusable rules / how-tos** — "always X", "never Y", "when you see Z, do W"
- **Non-obvious facts** — about an API, library quirk, environment, schema, build behavior
- **Decisions or events** — chose approach X over Y for reason Z; incident with lasting consequence
- **User corrections** — moments where the user redirected the agent's approach (these are gold)
- **Validated approaches** — when the user accepted/praised a non-obvious choice (also gold)

Discard candidates that are:
- Already obvious from reading the code or existing docs
- Trivial typos or one-off configuration the next agent will see in the file anyway
- Pure ephemeral state ("we're on commit X right now")

### 2. List Candidates Back to the User

Print a numbered list — one short line per candidate, plain language, **no type names**. Example:

```
I found 3 things worth saving from this session:
  1. The rule that DB tests must hit a real Postgres, not a mock.
  2. The fact that our Redis cluster only supports keys < 512 bytes.
  3. The decision to drop SSR support last Tuesday and why.

Which should I capture? Reply with the numbers (e.g. "1 and 3"), "all", or "none".
```

If nothing surfaces: tell the user plainly — "Nothing in this conversation feels worth remembering; the actionable parts are already in the code." — and stop.

### 3. For Each Selected Candidate, Classify Silently

Pick the type:

| Signal | Type |
|---|---|
| Actionable rule, do/don't, fix recipe | **procedural** |
| Stable fact about a system, API, environment | **semantic** |
| Dated event or decision with lasting consequence | **episodic** |

Tie-breaker: a candidate that says *what to do* is procedural; *what is true* is semantic; *what happened and why it still matters* is episodic.

### 4. Ask Targeted Clarifying Questions (per candidate)

Only ask what cannot be inferred from the conversation. Examples of plain-language questions (never name the type):

- "When should I apply this — any specific symptom or task?"
- "Any case where this rule should NOT be used?"
- "Is there a file I can point to so a future check confirms this is still true?"
- "Was this decision tied to a specific feature, or project-wide?"
- "Is this important enough that I should always have it in front of me, or just look it up when relevant?"

Batch questions per candidate so the user gets one prompt per memory, not a flood.

### 5. Draft Each Memory

Use `${aiDir}/.templates/memory-{type}.md`. Find next ID from `${aiDir}/memory/{type}/index.md` (highest + 1). Fill fields:

**Procedural**: `polarity` (positive/negative), `triggers`, `not_for`, `anchors` if code-specific. Body: Procedure → Why → What Fails → Verification.
**Semantic**: `topic`, `anchor` (file + pattern) if code-anchored, `source_session` if a session is active. Body: 1-3 sentence fact → Source → Implication.
**Episodic**: `date` (today or user-supplied), `outcome`, `persistent` (default false), `source_session` if active. Body: Context → Decision → Outcome → Consequence.

For multiple memories from one conversation, use `related` to cross-link IDs once they're all drafted.

### 6. Show Each Draft, Confirm One at a Time

For each candidate:

1. Render the full drafted file (frontmatter + body) plus the proposed index row.
2. Ask: "Save this one? **yes** to write, **edit** with changes, or **skip**."
3. Apply edits or skip; loop until user approves or skips.
4. On approval: write `${aiDir}/memory/{type}/{id}-{slug}.md` and append the row to the type index. Bump `updated` date in index frontmatter.

Do this sequentially per candidate so the user can stop the run at any point.

### 7. Cross-Link Related Memories

After all approved memories are written, if two or more came from the same conversation, edit each file's `related:` field to reference the others' IDs.

### 8. Optional: Layer 1 Promotion

For any memory the user flagged as critical (or that you believe is critical based on their answers in step 4), ask:

> "Should this be in the always-loaded index so I see it every session?"

If yes, add a one-line summary to the appropriate section of `${aiDir}/memory/index.md`.

### 9. Report

End with a short tally: "Saved N memories: <ID> <ID> <ID>. Skipped M." No type names.

## Verification Checklist

- [ ] Conversation actually scanned — candidate list reflects real turns, not invented content
- [ ] Memory types chosen silently — never named in user-facing output
- [ ] User explicitly chose which candidates to save (not auto-saved)
- [ ] Each draft shown and confirmed individually before write
- [ ] IDs incremented correctly per type
- [ ] Index rows contain keywords/topics only — no rule/fact/narrative leaked
- [ ] `related` cross-links added when multiple memories came from one run
- [ ] Final tally reported

## When NOT to Use

- User specified the exact content to save → use `/memorize` (REQUIRED for that path)
- User is wrapping up a tracked session → use `/session-complete` (REQUIRED for session wrap; extracts memories from the session log)
- Conversation was research-only with no decisions or surprises
- Conversation is short and contains nothing beyond a code edit already visible in the diff
