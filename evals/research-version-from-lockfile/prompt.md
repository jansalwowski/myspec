---
description: "Once research runs on a library behaviour question, it pins the version from the lockfile, tests the user's guess instead of adopting it, and dispatches search agents plus a verifier. The prompt starts the skill by its command; trigger-research grades routing."
tags: [skill:research, description-only, capability]
runs: 1
max_turns: 60
timeout_seconds: 1800
allowed_tools: [Read, Glob, Grep, Skill, Agent, ToolSearch, WebSearch, WebFetch]
---

/myspec:research We sometimes process the same Messenger message twice since we scaled our workers to 4 pods (Doctrine transport on MySQL 8). I think it's the redelivery timeout. Why does it happen and what's the proper fix?
