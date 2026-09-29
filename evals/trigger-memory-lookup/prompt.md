---
description: "Near-miss for the capture skills: \"have we hit this before?\" is a lookup (memory-lookup), not a capture (memorize / memorify)."
tags: [skill:memory-lookup, skill:memorize, skill:memorify, trigger, near-miss, regression]
max_turns: 6
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill]
---

The nightly invoice export died again with `psycopg.OperationalError: SSL SYSCALL error: EOF detected`. Have we run into this before? Check before we start digging.
