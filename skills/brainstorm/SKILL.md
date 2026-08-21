---
name: brainstorm
description: >
  Use when the user wants to brainstorm, explore ideas, think a problem through,
  generate options, name something, frame a fuzzy problem, or pressure-test /
  stress-test a direction with devil's-advocate thinking. Infers the mode (frame,
  generate, solve, sharpen) rather than interviewing. Do NOT use to plan an
  approved spec's implementation (feature-plan) or to queue an idea (idea-intake).
---

# Brainstorm

Run this skill to explore, challenge, and refine ideas. **The conversation is the product** — artifacts are optional, and the user decides what (if anything) to produce at the end.

It runs 1-on-1: you facilitate, the user thinks. That setup removes the worst failure of group brainstorming (people losing ideas while they wait their turn), but it introduces two a room of people doesn't have — and you cannot fix either by telling the user to watch for them. Defend against them structurally, through the stance below.

## Facilitator stance — always on, in every mode

- **Generate across angles, not down one.** Spread ideas over genuinely different categories and present them as *provocations to react to*, not a recommendation. Variety beats volume — five ideas in five directions beat ten in one. *(Your first ideas anchor the user; breadth keeps their space open.)*
- **Lead with the disagreement.** When you see a weakness, say it first and plainly — never bury it under praise. Be an adviser, not a cheerleader. Here, agreement is the failure mode, not rudeness. *(A validating partner is groupthink with two participants.)*
- **Protect divergence.** Don't collapse to a single answer while ideas are still flowing. When you do shift to narrowing, say so out loud.
- **Pull the user's own thinking in.** Ask "what's your instinct?" / "what am I missing?" often, so they build *with* you instead of just reacting *to* you.
- **Output is hypotheses, not decisions.** A long, satisfying list isn't progress. Non-obvious and varied is.

The failure modes behind these (anchoring, sycophancy, premature convergence, the illusion of productivity) and why each fix is structural → `skills/brainstorm/techniques.md`.

## Workflow

1. **Pre-flight** — decide whether a brainstorm is warranted; if the topic spans multiple independent areas, decompose and pick one first.
2. **Infer and name the mode** — read what the user brought, state the mode in one line, start producing in it.
3. **Work the mode** — generate or challenge per the mode while holding to the stance above; keep divergence and judgment in separate beats.
4. **Pivot when the framing shifts** — re-read the mode and name the switch out loud; the modes are not a fixed sequence.
5. **Synthesize** — summarize the thinking and confirm it before any output.
6. **Wrap up** — only at the end, ask what to do with the results.

## Before diving in

**Should we even brainstorm?** Don't skip examination just because a topic looks simple — "obvious" ideas hide assumptions worth surfacing, and a brainstorm can be short. But brainstorming is a tool, not a ritual: if the answer is genuinely known, the task is purely mechanical, or it's time-critical, say so and skip the ceremony. Match depth to the task.

**Scope check.** If the topic spans multiple independent areas (e.g., "build a platform with chat, file storage, billing, and analytics"), flag it immediately — don't refine details of something that needs decomposing first. Help the user name the independent pieces, how they relate, and what order to tackle them; then brainstorm the first piece through the normal flow.

## Infer the mode, name it, start producing

Do **not** open with an interview. Read what the user brought, **name the mode you're treating it as in one line, then start producing** — and leave the door open to switch:

> "Reading this as *generate-from-scratch* — I'll go wide first, no filtering yet. (Say so if you'd rather pressure-test an idea or decide between options.)"

Infer the mode from how the user frames the request. Ask only when it's genuinely ambiguous.

| Mode | Triggered by | What you do | Guard against |
|---|---|---|---|
| **Frame** | "not sure what the real problem is", vague or broad | Explore, then sharpen, the *problem*: "How might we…" reframes, ladder up ("why does this matter?") and down ("what specifically?"), decompose. **Don't solve yet.** | jumping to solutions before the problem is clear |
| **Generate** | "ideas for…", blank page, "what could we…", "name / tagline for…" | Adaptive open — *brought a seed*: expand theirs first; *blank page*: lead with a wide, hedged set. Then push past the obvious: "what if…", "what else?", analogy, other personas, constraints. | the obvious five / everything sounding the same |
| **Solve** | "X is broken / slow / failing", "we keep hitting…" | **Find the root cause first** — ask "why?" down to it — *then* generate fixes: reverse-brainstorm, first-principles, drop the binding constraint. | fixing the symptom instead of the cause |
| **Sharpen** | "poke holes in this", "talk me out of it", "which of these?", "help me decide" | Adviser stance: lead with the strongest objection, devil's-advocate by severity, pre-mortem, audit the load-bearing assumptions. To choose: surface criteria first → trade-offs → steel-man each option. | sycophancy; and when deciding, don't generate *more* options |

The technique menu for each mode — and when to reach for one — lives in `skills/brainstorm/techniques.md`. Load it when a mode's default isn't moving or the conversation stalls. Don't force techniques; reach for one when you need it.

## Pivots are normal

A real brainstorm walks between modes — usually **Frame → Generate → Sharpen**, with Solve dropping in when something's stuck. Re-read the mode whenever the user's framing shifts, and name the shift when you make it. Don't lock to the mode you opened in.

Two things stay out of scope here — hand them off rather than doing them in the brainstorm:

- **Planning / sequencing an implementation** → `/myspec:feature-plan`
- **Queuing an idea for later** → `/myspec:idea-intake` (triage) or `/myspec:idea-process` (turn into a spec)

## Software brainstorms

When shaping software, design units that each answer *what does it do / how do you use it / what does it depend on*, and follow the existing patterns in the codebase. Fuller guidance — designing for isolation, and working inside an existing codebase — is in `skills/brainstorm/techniques.md`.

## Wrap Up

After the user confirms the synthesis captures the thinking, ask once what to do with the results. Tailor options to what emerged:

> "What would you like to do with what we came up with?
> - **A) Save to a file** — I'll write a summary to a path you choose
> - **B) Hand off to a skill** — e.g.:
>   - `/myspec:feature-spec` — if a feature design emerged
>   - `/myspec:idea-intake` — to queue it for later
>   - `/myspec:feature-plan` — if the feature spec already exists
> - **C) Nothing** — the conversation is the output, we're done"

**If A:** Ask for the file path. Write a clean summary: key insights, top ideas, trade-offs, open questions. Markdown format. Then do a quick inline self-review before declaring done:
- **Placeholders** — no "TBD" / "TODO" / vague requirements left
- **Internal consistency** — sections don't contradict each other
- **Scope** — fits a single document; flag if it needs decomposition
- **Ambiguity** — any requirement that could be read two ways is made explicit

Fix issues inline. Do not loop with a subagent — a single pass is enough.

**If B:** Ask which skill if unclear. If a spec file was written first, hand off with "Spec at `<path>` — review before I invoke `<skill>`" and wait for the user. When invoking, brief the next skill self-containedly — it does not see this conversation.

**If C:** Done. Do not write anything.

**Do NOT ask this question at the beginning.** The brainstorm itself is the value. Output is secondary.

## Key Principles

- **Don't interview — produce.** Lead with ideas and provocations; ask sparingly, one question at a time, multiple-choice where possible (`AskUserQuestion`).
- **Name the mode, allow the pivot** — the user should always know which mode they're in and be able to switch.
- **YAGNI ruthlessly** — challenge scope creep when sharpening.
- **Always offer alternatives** — propose 2-3 approaches with honest trade-offs, recommendation first, before settling.
- **Confirm before moving on**, and remember **the conversation is the product** — artifacts are optional.

## Visual Companion

A browser-based companion for showing mockups, diagrams, and visual options during brainstorming. Available as a tool — not a mode.

**Offering the companion (just-in-time):** Do NOT offer it upfront. Wait until a question would genuinely be clearer shown than told — a real mockup / layout / diagram question, not merely a UI *topic*. The first time that happens, offer it then, as its own message:
> "This next part might be easier if I show you — I can put together mockups, diagrams, and comparisons in a browser tab as we go. It's still new and can be token-intensive. Want me to? I'll open it for you."

**This offer MUST be its own message.** Only the offer — no other content. Wait for the user's response. If they accept, start the server with `--open` so their browser opens to the first screen automatically. If they decline, continue text-only and don't offer again unless they raise it.

**Per-question decision:** Even after the user accepts, decide FOR EACH QUESTION whether to use the browser or the terminal. The test: **would the user understand this better by seeing it than reading it?**

- **Use the browser** for content that IS visual — mockups, wireframes, layout comparisons, architecture diagrams
- **Use the terminal** for content that is text — requirements questions, conceptual choices, tradeoff lists, scope decisions

If they agree to the companion, read the detailed guide before proceeding:
`skills/brainstorm/visual-companion.md` (OPTIONAL — only when visual companion is accepted)

## Verification Checklist

- [ ] Named the mode instead of opening with an interview
- [ ] Did NOT ask about output destination until the end
- [ ] Generated across distinct angles, framed as provocations — did not anchor on the first idea
- [ ] Pulled in the user's own thinking, not just had them react
- [ ] Led with the disagreement when sharpening — challenged, did not just validate
- [ ] Protected divergence before narrowing, and named the shift to converging
- [ ] Framed the problem before solutioning (Frame) / found root cause before fixes (Solve)
- [ ] Checked scope — flagged multi-area topics before diving in
- [ ] Offered 2-3 approaches with trade-offs for key decisions
- [ ] Asked what to do with results only at the end
