---
description: "The user hands over the exact fact to keep: memorize, not memorify or session-complete."
tags: [skill:memorize, skill:memorify, skill:session-complete, trigger, regression]
max_turns: 6
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill]
---

Remember this for next time: the staging database rotates its credentials every Monday at 06:00 UTC, so auth failures against staging right after that are expected; just re-pull the secret.
