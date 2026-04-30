# memorize — semantic fact with anchor

Capture a stable fact about a system. The interesting bit: the skill asks one targeted question to get an anchor so the fact can be re-verified later.

## Setup

The user just finished investigating why a Redis-backed cache silently dropped large session blobs. They learned the cluster has a 512-byte key limit configured at the proxy layer.

## Invocation

```
/memorize our redis cluster rejects keys longer than 512 bytes — it's a proxy-level limit, not a redis default
```

## Skill flow

*(Silent classification: stable fact about an environment → **semantic**.)*

The input is a clear fact, but there's no code reference yet. The skill asks one question:

> "Is there a file or config I can point to so a future check can re-verify this is still true?"

**User answers:**

```
yeah, infra/redis/proxy.conf — the key_max_length directive
```

**Agent renders the draft:**

```markdown
---
id: S007
type: semantic
topic: redis
anchor:
  file: infra/redis/proxy.conf
  pattern: "key_max_length"
verified: 2026-04-30
---

# Redis key length capped at 512 bytes by proxy

The Redis cluster enforces a 512-byte maximum key length at the proxy
layer, not in Redis itself. Keys longer than this are silently
rejected by the proxy before reaching Redis.

## Source
`infra/redis/proxy.conf` — `key_max_length` directive.

## Implication
Session keys, cache namespaces, and any composed keys (e.g.
`tenant:{uuid}:user:{uuid}:cart`) must stay under 512 bytes including
the namespace prefix. Use hashed keys for anything user-controlled.
```

**Proposed index row** (`memory/semantic/index.md`):

```
| S007 | redis, key-length, proxy | 2026-04-30 |
```

> Save this? Reply **yes** to write it, or tell me what to change.

## User confirms

```
yes
```

## Result

- Wrote `${aiDir}/memory/semantic/S007-redis-key-length-cap.md`.
- Appended row to `${aiDir}/memory/semantic/index.md`.

## Why this example matters

Shows the skill **asking exactly one** clarifying question — the anchor — and nothing more. The user supplied the fact, the rationale, and the layer of enforcement; only the verification target was missing. The skill never said the word "semantic" or "anchor" out loud.
