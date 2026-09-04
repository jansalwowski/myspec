---
name: "memorize"
description: "Use when the user names the exact thing to remember inline, e.g. '/memorize the prod DB is in us-east-1'. Captures one memory per call. Do NOT use to sweep the conversation for candidates (memorify) or to edit an existing memory."
---

# Memorize

Direct, single-shot capture: user hands over the content, skill turns it into a properly-classified memory entry.

## Input

The skill receives the raw content to memorize as `args` (everything after `/memorize`). Treat that string as the user's intent — do not invent additional facts.

If `args` is empty, ask the user once: "What would you like me to remember?" — then proceed.

## Constraints

- **Never expose memory-type terminology to the user.** Words like "procedural", "semantic", "episodic", "anchor", "polarity" must not appear in any user-facing message. Classify silently.
- One `/memorize` call produces **exactly one** memory. If the input bundles multiple distinct insights, surface that and ask the user which one to capture (or suggest running `/memorify` to handle several at once).
- Index entries contain keywords/topics ONLY — never the full rule, fact, or narrative.
- Always show the drafted memory and wait for confirmation before writing.

## Workflow

### 1. Classify the Content (silently)

Read the user's input and pick the type that fits best:

| Signal in user's input | Type |
|---|---|
| "always do X", "never do Y", "when X happens, do Y", "the way to fix Z is…", a rule or pattern | **procedural** |
| "X is true", "the API returns Y", "library Z behaves like W", a stable fact about a system | **semantic** |
| "we decided X on <date>", "incident with Y caused Z", a one-time event with lasting consequence | **episodic** |

Tie-breakers:
- Actionable instruction → procedural.
- Reference fact someone would look up → semantic.
- Dated event explaining *why* the codebase looks the way it does → episodic.

### 2. Identify Missing Fields (ask only what you need)

Inspect the input against the type's required fields (see Step 4). If all required fields are derivable, **skip asking** and move on. Otherwise ask short, plain-language questions — one batch, no jargon. Examples:

- Procedural without a clear trigger: "When should I apply this — what symptoms or task should trigger it?"
- Procedural without exclusions: "Is there a case where this rule should NOT be applied?"
- Semantic without an anchor: "Is there a file or command where this fact can be re-verified later?"
- Episodic without a date: "Roughly when did this happen?" (default to today if user can't recall)
- Any type, scope unclear: "Is this specific to a feature, or applies project-wide?"

Do NOT ask about memory type, IDs, polarity, validation count, or template fields — infer or default those.

### 3. Delegate to memory-create

**REQUIRED:** Invoke `/myspec:memory-create` with the classified type, the user's content, and the Step 2 answers. It owns the shared write path: the consolidation check (ADD / UPDATE / NO-OP — prevents duplicate entries), ID assignment, template fill, draft approval, index row, and optional Layer 1 promotion. Do not draft or write memory files in this skill.

The Constraints above still govern the user-facing conversation throughout: type vocabulary stays internal, and the draft must be shown and approved before any write. If memory-create's check returns NO-OP or UPDATE, relay that plainly ("already covered by an existing note — updated it instead") without exposing IDs or type names unprompted.

## Verification Checklist

- [ ] Memory type chosen silently — never named in user-facing output
- [ ] Clarifying questions only asked when a required field couldn't be inferred
- [ ] Exactly one memory per invocation handed to `/myspec:memory-create`
- [ ] Consolidation check ran (ADD / UPDATE / NO-OP) — no duplicate entry created

## When NOT to Use

- The user wants the conversation scanned for memorable items → use `/myspec:memorify` (OPTIONAL — separate flow)
- The user is correcting an existing memory → edit that memory directly
- The "fact" is something a future agent could trivially derive from reading code or docs
