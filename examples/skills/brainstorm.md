# `/myspec:brainstorm` — examples

Structured idea exploration: divergent generation → convergent challenge → synthesis. The conversation is the product — artifacts are optional. The user decides at the end whether anything graduates to `ideas/` or a feature spec.

**Contents**

- [Standard divergent → convergent flow](#standard-divergent--convergent-flow)
- [Topic too large — skill helps decompose first](#topic-too-large--skill-helps-decompose-first)
- [Devil's advocate / stress-test mode](#devils-advocate--stress-test-mode)

---

## Standard divergent → convergent flow

The default shape: vague idea, agent generates broadly, then narrows down with trade-offs.

### Setup

The user has a hunch they want to explore: *"What if reports could embed each other — like, a report can include a chart from another report?"* Not a spec yet, just a direction.

### Invocation

```
/myspec:brainstorm reports embedding other reports
```

### Skill flow

#### 1. Explore context

The agent reads `ai/features/reports/spec.md`, the dashboards feature spec, and looks at how charts are currently rendered. Notes the current model: each report owns its charts, no cross-report references.

#### 2. Scope check

Manageable scope (single capability area, one feature). No decomposition needed. The skill proceeds.

#### 3. DIVERGENT — generate broadly

The agent fans out without filtering:

- Embed by reference (live link to the other report's chart)
- Embed by snapshot (frozen copy of the chart at embed time)
- Embed via portal-style "include" tag in a markdown report
- Auto-embed: a report can declare "show me trending charts from related reports"
- Embed with parameter passing — embedded chart re-renders against the parent report's filter context
- Embed entire reports as iframes (extreme version)
- Permission-aware embedding: embed fails gracefully if viewer lacks access to source report

Seven options across two axes (snapshot vs. live, content scope).

#### 4. CONVERGENT — challenge and narrow

The agent stress-tests:

- *"Live embedding sounds great until the source report changes shape — how do consumers handle a deleted chart?"*
- *"Permission-aware embedding requires per-render auth checks. Cheap if rare, expensive if every report embeds many."*
- *"Snapshot is simpler but creates a 'copy decay' problem — embeds drift from source."*

Proposes three approaches:

| Approach | Trade-off |
|----------|-----------|
| **A) Live embed by reference** | Always fresh; breaks loudly when source moves. Permission-aware. Higher render cost. |
| **B) Snapshot embed** | Frozen at insert time; never breaks. No permission check needed (snapshot already authorized). Decays over time. |
| **C) Hybrid: live with snapshot fallback** | Best UX; most complex. Worth only if both cases are common. |

#### 5. Synthesize

> The interesting design question is **whether embeds should track the source or freeze it**. That's where the user-perceived behavior diverges. Permission semantics, missing-chart UX, and update propagation all flow from that one choice.
>
> If you want to ship something soon, **B (snapshot)** is the lowest-risk path — closest in shape to your existing report-export pattern. **A** is more ambitious; **C** only earns its complexity if you've validated demand.

#### 6. Wrap up

> What would you like to do with this?
>
> - Drop it as an idea in `ideas/` for later
> - Spec it now (`/myspec:feature-spec`)
> - Throw it away — exploration was enough
> - Keep brainstorming, narrow further

**User**: drop as idea, leaning option B.

The agent writes `ideas/report-embedding.md` capturing the synthesis, the chosen direction (snapshot), and the rejected alternatives with their reasons.

### Why this example matters

- **The conversation IS the product.** The trade-off table is what the user takes away — even if they never write a spec.
- **Convergent ≠ pick the easy one.** The agent didn't recommend "the simplest"; it recommended the one that matches the user's apparent risk tolerance ("if you want to ship soon"). Tone-aware.
- **Rejected alternatives are first-class.** They go into the ideas file too. When someone re-opens this in six months, they'll know A and C were considered, not just "B was the only option."
- **No spec is also a valid outcome.** The user can throw away the brainstorm — the value was in the structured exploration.

---

## Topic too large — skill helps decompose first

Some "ideas" are actually programs. The skill notices and helps the user split before generating ideas under each piece.

### Setup

User: *"I want to brainstorm: making our reporting platform an open extensible ecosystem — third-party plugins, marketplace, revenue sharing, plugin sandboxing, all of it."*

### Invocation

```
/myspec:brainstorm open ecosystem for reports — plugins marketplace revenue sandboxing
```

### Skill flow

#### 1. Explore context

The agent skims the relevant areas. There's nothing in the codebase or specs about extensibility. This is a from-scratch ambition.

#### 2. Scope check — flagged

> What you described spans at least four independent decision domains:
>
> 1. **Plugin runtime / sandboxing** — how plugins execute safely (server-side? client-side WASM? iframes?)
> 2. **API surface** — what plugins can call, read, write, hook into
> 3. **Marketplace + discovery** — listing, ratings, search, install flows
> 4. **Commerce — pricing, payments, revenue share, taxation**
>
> Each is months of work and depends on choices in the others (you can't design pricing without knowing what plugins can do). A single brainstorm here will be too thin — we'll generate plausible-sounding ideas in each area without the depth to be useful.
>
> Two options:
>
> - **A) Pick one area to brainstorm now.** Plugin runtime is the foundational choice — the rest follows. I'd recommend that.
> - **B) High-level only — sketch each area briefly, identify which has the most uncertainty, and brainstorm that one in depth next session.**

**User**: A — runtime.

#### 3. Re-scoped: divergent on plugin runtime

The agent generates 5 runtime options (server-side eval, WASM in browser, isolated container per plugin, declarative DSL only, hybrid). Convergent: WASM is the standout — sandboxing is "free" (browser handles it), but capability surface is limited; declarative DSL is even simpler but most restrictive; container-per-plugin is the most powerful but operationally heavy.

#### 4. Wrap up

User asks the skill to drop the synthesis as an idea AND to leave a meta-idea referencing the other three areas (API surface, marketplace, commerce) as future brainstorm targets.

The agent writes:

- `ideas/plugin-runtime.md` — the focused brainstorm output.
- `ideas/extensibility-roadmap.md` — meta-idea listing all four areas with notes on which are still unbrainstormed.

### Why this example matters

- **Refusal-by-decomposition is a feature.** The skill's worst failure mode is producing 4 paragraphs of "thoughts" on a topic that needs 4 hours each. Naming the structure and asking the user to pick is the right move.
- **Meta-ideas are a useful artifact.** A roadmap-style ideas file points at the work that hasn't yet been brainstormed — visible in the ideas pipeline so it doesn't get lost.

---

## Devil's advocate / stress-test mode

The user has a direction they're committed to and wants the skill to *attack* it before they spec. Different mode — less generation, more challenge.

### Setup

User has decided: *"I'm going to remove all our background workers and run everything as serverless functions. Talk me out of it before I commit."*

### Invocation

```
/myspec:brainstorm devil's advocate: replace all background workers with serverless functions
```

### Skill flow

The skill recognizes the framing ("talk me out of it") and skips divergent — goes straight to convergent stress-test.

#### Challenges, in order of severity

1. **Cold-start latency.** Your jobs include the analytics rollup (long-running, every Monday). Serverless cold-start adds 1-3s; for a 25-minute job that's noise. But your real-time webhook processor would feel it on every burst — is the latency acceptable?

2. **Execution time limits.** Most serverless platforms cap function execution at 15 minutes. Your weekly rollup currently runs 25 minutes. Can it be chunked, or does it need to stay on a worker?

3. **Connection pooling.** Workers reuse DB connections. Serverless functions create new connections per invocation (or via a connection pool service like RDS Proxy / pgbouncer). On a bursty workload, you can saturate connections fast — and your staging pool is sized 5 (per memory P019). This is a known foot-gun.

4. **State machines and retries.** Long-running stateful jobs (multi-step exports, etc.) are awkward in serverless. You'd need a state-machine layer (Step Functions / Inngest / Trigger.dev) on top — that's not "removing workers", it's replacing them with managed equivalents.

5. **Cost shape.** Workers: predictable monthly cost. Serverless: variable per-invocation. For a stable workload, serverless is often *more* expensive at scale. Have you modeled the cost?

6. **Local development.** Workers run locally with `pnpm dev`. Serverless usually requires emulation tooling that's flakier. DX hit is real.

7. **Lock-in.** Serverless functions are platform-specific (Lambda / Cloud Functions / Workers). You're trading one form of operational complexity for vendor lock-in.

#### Synthesize the attack

> If you're committed, the strongest counter-arguments are: cold starts on the webhook path, the 15-minute cap on the analytics rollup, and connection-pool saturation. The first two are blockers without significant rework; the third is a foot-gun you've already been bitten by (P019).
>
> The interesting question isn't "serverless yes/no" — it's **"which workloads benefit, and which should stay on workers?"** Mixed-mode is almost always the right answer. A clean replacement is rare.
>
> Want me to brainstorm the mixed-mode design?

**User**: yes.

The skill pivots to a fresh divergent → convergent on which workloads to migrate vs. keep — much more productive than the all-or-nothing framing.

### Why this example matters

- **"Talk me out of it" is a real mode.** When the user is already committed, divergent generation is wasted effort — they need stress-tests, not alternatives.
- **The skill draws on memories.** P019 (the connection-pool incident) is referenced because bootstrap loaded it earlier in the session. This is what makes brainstorm contextually intelligent vs. generic.
- **Reframe as an outcome.** The skill ended by reframing the question from binary ("replace all") to scoped ("which workloads"). That's a more useful frame and the user took it. Good devil's advocacy doesn't just block — it redirects.
