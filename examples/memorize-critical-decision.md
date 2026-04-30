# memorize — critical decision with Layer 1 promotion

The most involved memorize flow: a dated decision that the user wants surfaced in **every** future session. Demonstrates the optional Layer 1 promotion step.

## Setup

After a long architecture discussion, the team decided to drop server-side rendering from the marketing site and go fully static. The decision is irreversible-ish (CDN config, build pipeline, hiring assumptions all key off it) and several months of future work depend on remembering *why*.

## Invocation

```
/memorize on 2026-04-22 we dropped SSR from the marketing site — going fully static via the build pipeline. reason was hosting cost and the SEO win from edge-cached HTML. this is really important, future agents need to know
```

## Skill flow

*(Silent classification: dated event with lasting consequence → **episodic**. The "really important" phrasing is a strong Layer 1 signal.)*

Required fields are mostly present (date, context, decision, reason). The skill asks one question to confirm scope:

> "Was this decision tied just to the marketing site, or does it apply to the whole product suite?"

**User answers:**

```
just marketing — the app itself stays SSR
```

**Agent renders the draft:**

```markdown
---
id: E009
type: episodic
date: 2026-04-22
outcome: success
persistent: true
feature: marketing-site
related: []
verified: 2026-04-30
---

# Dropped SSR from the marketing site

## Context
The marketing site had been served via a Node SSR layer fronted by
Cloudflare. As traffic grew, hosting cost climbed and the SSR layer
became the slowest hop in the request path. SEO audits also showed
edge-cached static HTML scored materially better than dynamically
rendered pages.

## Decision
On 2026-04-22 we dropped SSR for the marketing site and moved to a
fully static build deployed to the edge. Scope is **marketing site
only** — the product app keeps its SSR setup.

## Outcome
Hosting cost on the marketing surface dropped, and Core Web Vitals
improved across the board. No regressions surfaced in the first week.

## Consequence
- The Node SSR runtime, its Dockerfile, and the related deploy job
  are gone from the marketing repo.
- Any future "make this page dynamic" request needs an explicit
  carve-out (client-side fetch, edge function, or a dedicated route
  outside the static build) — don't quietly reintroduce SSR.
- Hiring and ops planning for the marketing surface assumes static
  hosting; revisiting that needs a real reason.
```

**Proposed index row** (`memory/episodic/index.md`):

```
| E009 | marketing-site, ssr, static, hosting-cost, seo | 2026-04-30 |
```

> Save this? Reply **yes** to write it, or tell me what to change.

**User confirms:**

```
yes
```

## Layer 1 promotion

Because the user flagged this as critical ("future agents need to know"), the skill asks:

> "Should this also live in the always-loaded memory index so I see it every session?"

**User:**

```
yes please
```

The agent appends a one-line summary under the **Decisions** section of `${aiDir}/memory/index.md`:

```markdown
- **E009** Marketing site is fully static (no SSR) since 2026-04-22 — don't reintroduce SSR without an explicit carve-out.
```

## Result

- Wrote `${aiDir}/memory/episodic/E009-drop-ssr-marketing.md`.
- Appended row to `${aiDir}/memory/episodic/index.md`.
- Added one-line summary to Layer 1 `${aiDir}/memory/index.md`.

## Why this example matters

- **Episodic** memory carries the *why* a decision was made, which doesn't live in any commit.
- **`persistent: true`** keeps it from being archived during normal memory pruning.
- **Layer 1 promotion** is reserved for things that change how *every* session should reason — not for ordinary rules. The skill only offers it when the user signals criticality.
