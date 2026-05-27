# `/myspec:brainstorm` — examples

Mode-based facilitation. The agent reads what the user brought, **infers the mode** (Frame, Generate, Solve, Sharpen), **names it out loud**, and starts producing — no opening interview. It keeps divergence and judgment in separate beats, pivots when the framing shifts (announcing the pivot), and only at the very end asks what to do with the result. **The conversation is the product** — artifacts are optional.

**Contents**

- [Generate mode — infer, go wide, converge, hand off](#generate-mode--infer-go-wide-converge-hand-off) — names the mode, diverges then narrows, ends with a hand-off to `/myspec:idea-intake`
- [Topic too large — scope check recommends decomposing](#topic-too-large--scope-check-recommends-decomposing) — pre-flight catches a multi-area topic and splits before generating
- [Sharpen mode that pivots to Generate](#sharpen-mode-that-pivots-to-generate) — devil's-advocate stress-test that re-reads the framing mid-session and announces the pivot

The named techniques (How Might We, Laddering, SCAMPER, Six Hats, reverse brainstorming, first-principles, pre-mortem, 5 Whys, …) live in `skills/brainstorm/techniques.md`; the agent reaches for them naturally and rarely labels them out loud. Where a technique is doing the work below, it's noted in an *italic side-note* so you can see the reasoning.

---

## Generate mode — infer, go wide, converge, hand off

The default shape of a from-a-seed session: the user brings a direction, the agent names the mode, fans out across distinct angles as provocations, then narrows with trade-offs, and finishes by handing the synthesis to the ideas queue.

### Setup

The user has a hunch they want to explore: *"What if reports could embed each other — a report can include a chart that lives in another report?"* Not a spec, just a direction. There's an existing `reports` feature where each report owns its own charts; no cross-report references today.

### Invocation

```
/myspec:brainstorm reports embedding charts from other reports
```

### Skill flow

#### 1. Pre-flight

Worth a brainstorm — the answer isn't known, it isn't mechanical, and nothing is time-critical. Single capability area, one feature: no decomposition needed. The agent skims `ai/features/reports/spec.md` and how charts render today, then proceeds.

#### 2. Infer and name the mode

The user brought a seed and wants options, not a critique. The agent names it in one line and leaves the door open:

> "Reading this as **generate-from-scratch** — I'll expand your embedding idea first and go wide, no filtering yet. (Say so if you'd rather pressure-test one approach or decide between options.)"

#### 3. Work the mode — divergent beat

*(Diversity pressure + "what else?": spread across genuinely different axes, framed as provocations, not picks.)*

> "Here are seven angles, deliberately spread out — react to whichever pull at you:
>
> - **Embed by reference** — a live link to the other report's chart; always current.
> - **Embed by snapshot** — a frozen copy taken at embed time; never changes.
> - **Include tag** — a portal-style `{{embed:…}}` token in a markdown report.
> - **Auto-embed by rule** — 'show trending charts from related reports' rather than naming one.
> - **Parameterized embed** — the embedded chart re-renders against the *parent* report's filter context.
> - **Whole-report embed** — iframe the entire source report (the extreme version).
> - **Permission-aware embed** — degrades gracefully when the viewer can't see the source.
>
> Before I react to these — what's your instinct on whether an embed should *track* the source or *freeze* it? That's the fork everything else hangs off."

**User:** track it, ideally. stale charts would confuse people.

#### 4. Work the mode — judgment beat (named shift)

> "Good — that narrows us. Switching from generating to **narrowing** now. Holding you to 'track the source,' here's where that bites:"

*(Devil's advocate by severity, held in its own beat — not mixed into generation.)*

- *"Live tracking is great until the source report changes shape. What does a consumer see when the embedded chart is **deleted** — a broken tile, a tombstone, a silent drop?"*
- *"Tracking means a permission check **per render** — cheap if embeds are rare, a real cost if every report embeds many."*
- *"Snapshot dodges both problems but reintroduces the staleness you just rejected. So the honest framing is: you're buying freshness and paying in failure-handling."*

Three approaches, recommendation first:

| Approach | Trade-off |
|----------|-----------|
| **A) Live embed by reference** | Always fresh (matches your instinct); permission-aware; breaks loudly when the source moves; higher render cost. |
| **B) Snapshot embed** | Never breaks; no per-render auth (already authorized at insert); but decays — the thing you said you didn't want. |
| **C) Live with snapshot fallback** | Best UX; most complex; only earns its keep if both fresh-and-broken cases are common. |

#### 5. Synthesize

> "Pulling it together: the load-bearing decision is **track vs. freeze**, and you've landed on track. Given that, **A (live by reference)** is the honest match — *if* we also design the missing-chart UX up front (tombstone tile + 'source removed' state) and cap the per-render permission cost. **C** is the same idea with a safety net; worth it only once you've seen real breakage. The open question I'd flag: how a chart deletion in the source propagates to embeds. Does that capture it?"

**User:** yes, that's the thing.

#### 6. Wrap up

Only now does the agent ask what to do with the result:

> "What would you like to do with what we came up with?
> - **A) Save to a file** — I'll write a summary to a path you choose
> - **B) Hand off to a skill** — e.g. `/myspec:idea-intake` to queue it, or `/myspec:feature-spec` to spec it now
> - **C) Nothing** — the conversation was the output"

**User:** queue it — option B, idea-intake. leaning approach A.

The agent briefs `/myspec:idea-intake` self-containedly (it doesn't see this conversation): the embedding idea, the track-vs-freeze decision, approach **A** as the leaning direction, **B** and **C** as rejected alternatives with reasons, and the open question about deletion propagation.

### Why this example matters

- **Infer-and-name replaces the interview.** The agent stated the mode in one line and started producing immediately — no "what are you hoping to get out of this?" preamble.
- **Divergence and judgment stayed in separate beats**, and the shift to narrowing was announced out loud ("Switching to narrowing now").
- **The user's own thinking was pulled in early** ("what's your instinct on track vs. freeze?") — they built *with* the agent, not just reacted.
- **The hand-off is briefed, not assumed.** `idea-intake` receives the synthesis, the chosen direction, *and* the rejected alternatives — so the queue entry is decision-complete on its own.

---

## Topic too large — scope check recommends decomposing

Some "ideas" are actually programs. Pre-flight catches a multi-area topic and helps the user split before generating anything under each piece.

### Setup

User: *"I want to brainstorm making our reporting platform an open, extensible ecosystem — third-party plugins, a marketplace, revenue sharing, plugin sandboxing, all of it."*

### Invocation

```
/myspec:brainstorm open plugin ecosystem for reports — marketplace, revenue share, sandboxing
```

### Skill flow

#### 1. Pre-flight — scope check, flagged

The agent skims for existing extensibility work (none — this is from scratch) and immediately recognizes the topic spans several independent areas. Rather than refine details of something that needs decomposing first, it names the structure:

> "What you described spans at least four independent decision domains:
>
> 1. **Plugin runtime / sandboxing** — how plugins execute safely (server-side? client-side WASM? iframe-isolated?)
> 2. **API surface** — what plugins can read, write, and hook into
> 3. **Marketplace & discovery** — listing, ratings, search, install flow
> 4. **Commerce** — pricing, payments, revenue share, taxation
>
> Each is months of work, and they depend on each other — you can't design pricing without knowing what plugins can *do*. One brainstorm across all four would be too thin: plausible-sounding ideas in each area without the depth to be useful.
>
> Two ways to play it:
>
> - **A) Pick one area now.** Plugin runtime is the foundational choice — the others follow from it. I'd start there.
> - **B) Stay high-level** — sketch each area briefly, find the one with the most uncertainty, and brainstorm *that* one in depth next."

**User:** A — runtime.

#### 2. Infer and name the mode (re-scoped)

With one area chosen, the agent names the mode for the focused topic:

> "Reading runtime as **generate-from-scratch** — going wide on execution models first, then we'll narrow on the safety/capability trade-off."

#### 3. Work the mode

*(Diversity pressure across distinct categories.)* The agent fans out — server-side eval, client-side WASM, container-per-plugin, declarative-DSL-only, hybrid — then shifts (announced) into the judgment beat: WASM is the standout, since the browser sandboxes it "for free," but its capability surface is narrow; the declarative DSL is simpler still but the most restrictive; container-per-plugin is the most powerful but operationally heavy.

#### 4. Synthesize & wrap up

After confirming the synthesis, the agent asks what to do. The user picks **A) Save to a file** for the runtime work *and* asks for a second file capturing the four-area structure as future brainstorm targets.

The agent writes both, then runs an inline self-review on each (placeholders / internal consistency / scope / ambiguity):

- `ideas/plugin-runtime.md` — the focused brainstorm: options, the WASM recommendation, rejected alternatives with reasons.
- `ideas/extensibility-roadmap.md` — a meta-idea listing all four domains, which are still unbrainstormed, and the dependency between them.

Self-review catches one ambiguity in the roadmap file ("sandboxing" appearing both as area 1's name and inside the runtime notes) and disambiguates it inline. Single pass, no subagent loop.

### Why this example matters

- **Refusal-by-decomposition is the feature, not a dodge.** The skill's worst outcome here would be four shallow paragraphs on a topic that needs four deep sessions. Naming the structure and asking the user to pick is the right move.
- **Pre-flight does real work.** The scope check happens *before* any generation — the agent never starts diverging on an undecomposed topic.
- **Meta-ideas keep the rest visible.** The roadmap file points at the unbrainstormed domains so they don't get lost — and the inline self-review keeps the written artifacts clean.

---

## Sharpen mode that pivots to Generate

The user is committed to a direction and wants it attacked. The agent infers **Sharpen**, names it, leads with the strongest objection — then notices the framing has shifted and **announces a pivot to Generate**.

### Setup

User has decided: *"I'm going to replace all our background workers with serverless functions. Talk me out of it before I commit."* Earlier in the session, bootstrap loaded memory **P019** (a connection-pool saturation incident on a pool sized 5 in staging).

### Invocation

```
/myspec:brainstorm talk me out of replacing all background workers with serverless functions
```

### Skill flow

#### 1. Pre-flight

A genuine decision with real downside — worth pressure-testing, not skipping. Single scope. Proceed.

#### 2. Infer and name the mode

"Talk me out of it" + a committed direction is unambiguous:

> "Reading this as **sharpen** — you've got a direction, you want it attacked. I'll lead with the strongest objection and work down by severity, no cheerleading. (If you'd rather generate the *alternative* designs, say so.)"

#### 3. Work the mode — devil's advocate by severity

*(Adviser stance: objection first and plainly, ordered by severity — and no generating new options, this is the deciding beat.)*

1. **Execution-time cap.** Most serverless platforms cap a single invocation at 15 minutes. Your weekly analytics rollup runs ~25. Either it chunks cleanly or it can't move — this is a hard blocker, not a tuning problem.
2. **Cold-start on the hot path.** The rollup won't care about a 1–3s cold start; the real-time webhook processor will feel it on every burst. Is that latency acceptable on the path that's actually latency-sensitive?
3. **Connection-pool saturation.** Workers reuse DB connections; serverless opens one per invocation unless you front it with a proxy. On a bursty load you saturate fast — and per **P019** your staging pool is sized 5 and *already* bit you once. This is a known foot-gun for you specifically.
4. **State & retries.** Multi-step stateful jobs get awkward; you'd bolt on a state-machine layer (Step Functions / Inngest / Trigger.dev). That's not *removing* workers — it's replacing them with managed equivalents.
5. **Cost shape & lock-in.** Predictable monthly worker cost becomes variable per-invocation cost, often *higher* at steady scale; and functions are platform-specific. You'd trade operational complexity for vendor lock-in.

#### 4. Pivot — announced out loud

The objections cluster around *some* workloads, not all — the binary framing is the real problem. The agent re-reads the mode and names the switch:

> "Here's where I'll **pivot from sharpening to generating** — because the honest answer to 'talk me out of it' is that the *all-or-nothing framing* is the weak part, not serverless itself. The 15-minute cap and the webhook cold start are blockers for specific jobs; the pool saturation (P019) is a foot-gun you've already hit. So the useful question isn't 'serverless: yes/no' — it's **'which workloads move and which stay on workers?'**
>
> Switching to generate on the mixed-mode split. Want me to go?"

**User:** yes, do that.

#### 5. Work the new mode

*(Now Generate — diverge on the split.)* The agent sorts the workloads into "good serverless fits" (short, bursty, stateless — e.g. webhook fan-out, thumbnail generation), "keep on workers" (the 25-minute rollup, anything holding DB connections through a burst), and "needs a managed state layer either way" (multi-step exports) — then narrows to a recommended mixed-mode boundary.

#### 6. Synthesize & wrap up

After confirming the synthesis, the agent asks what to do with it. (Not shown — same A/B/C menu as the other scenarios; the user could save it, hand the mixed-mode design to `/myspec:feature-spec`, or stop.)

### Why this example matters

- **Sharpen is inferred and named** from "talk me out of it" — the agent skipped generation entirely and went straight to objections, because a committed user needs stress-tests, not more options.
- **The pivot is the point.** A real brainstorm walks between modes; here the agent re-read the framing, decided the binary question was the actual weakness, and **announced the switch from Sharpen to Generate** instead of silently sliding into it.
- **Memory makes it contextual.** P019 (the connection-pool incident, loaded at bootstrap) turns a generic objection into a specific, personal one — this is what separates brainstorm from a stock pros-and-cons list.
- **Good devil's advocacy redirects, it doesn't just block.** The strongest critique wasn't "no" — it was a better frame ("which workloads"), and the user took it.
