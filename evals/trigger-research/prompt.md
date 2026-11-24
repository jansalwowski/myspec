---
description: "A request to compare background-job libraries with sourced trade-offs routes to research, not brainstorm or root-cause-debugging."
tags: [skill:research, skill:brainstorm, skill:root-cause-debugging, trigger, capability]
runs: 1
max_turns: 2
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill]
---

We send invoice PDFs and reminder emails inline in the Flask request handlers and it's getting slow. Look into whether we should move this to Celery, RQ or Dramatiq. We already run PostgreSQL and could add Redis. I want the trade-offs backed by sources, not opinions.
