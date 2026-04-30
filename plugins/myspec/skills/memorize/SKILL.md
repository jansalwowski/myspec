---
name: "memorize"
description: "Use when the user explicitly asks to remember, save, or memorize a specific piece of information given inline. Example invocations: '/memorize we always run pnpm db:generate after install', '/memorize the prod DB is in us-east-1'. Captures one memory per call; memory-type vocabulary stays internal. Do NOT use to scavenge memories from conversation context (use /memorify), to edit existing memories, or for trivial config already visible in code or docs."
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

### 3. Find Next ID

Read `${aiDir}/memory/{type}/index.md`. Find the highest existing ID for that type and increment by 1 (e.g., `P012` → `P013`). For an empty index, start at `P001` / `S001` / `E001`.

### 4. Draft the Memory File

Use `${aiDir}/.templates/memory-{type}.md` as the structure. Fill fields based on user input + answers:

**Procedural** (`memory-procedural.md`):
- `polarity`: `positive` (rule to follow) or `negative` (anti-pattern)
- `triggers`: keywords from when-to-apply
- `not_for`: 1-3 explicit exclusions (use the user's answer or your best inference; if none, write a sensible default)
- `anchors`: `[{file, pattern}]` if code-specific
- Body: **Procedure (Do This)** → **Why This Works** → **What Fails** → **Verification**

**Semantic** (`memory-semantic.md`):
- `topic`: 1-2 word domain keyword
- `anchor`: `{file, pattern}` to re-verify later (skip if no code anchor exists)
- Body: 1-3 sentence fact + **Source** + **Implication**

**Episodic** (`memory-episodic.md`):
- `date`: today (or the date the user gave)
- `outcome`: `success | failure | partial | abandoned`
- `persistent`: `false` by default; `true` only if user signaled lasting/forever relevance
- Body: **Context** → **Decision** → **Outcome** → **Consequence**

`feature` field: set if input clearly references a feature directory under `${aiDir}/features/`; otherwise leave empty.
`related`: skip on first capture unless the user pointed at another memory ID.

### 5. Show the Draft to the User

Render the full drafted file (frontmatter + body) in the chat. Add the proposed index row underneath. Then ask:

> "Save this? Reply **yes** to write it, or tell me what to change."

Do NOT mention the memory type in this prompt. The user just sees the content and approves.

### 6. Apply Edits or Write

- If user requests changes: revise and re-show. Loop until approved.
- If user approves: write `${aiDir}/memory/{type}/{id}-{slug}.md` and append the row to `${aiDir}/memory/{type}/index.md`. Bump the index frontmatter `updated` date.

### 7. Optional: Layer 1 Promotion

If the memory looks critical (e.g., user said "this is really important", "always remember this"), ask:

> "Should this also live in the always-loaded memory index so I see it every session?"

If yes, append a one-line summary to the appropriate section of `${aiDir}/memory/index.md`.

## Verification Checklist

- [ ] Memory type chosen silently — never named in user-facing output
- [ ] Clarifying questions only asked when a required field couldn't be inferred
- [ ] Exactly one memory drafted per invocation
- [ ] User saw the full draft and explicitly approved before write
- [ ] ID incremented from the type-specific index
- [ ] Index row contains keywords/topics only — no rule body leaked
- [ ] `validated`/`verified` date set to today

## When NOT to Use

- The user wants the conversation scanned for memorable items → use `/memorify` (OPTIONAL — separate flow)
- The user is correcting an existing memory → edit that memory directly
- Information is already covered by an existing memory (OPTIONAL — check `/memory-lookup` first if unsure)
- The "fact" is something a future agent could trivially derive from reading code or docs
