---
description: "Once research runs on a tool choice, it checks the candidate library's maintenance state from its repository and covers the downside of the option it recommends."
tags: [skill:research, description-only, capability]
runs: 1
max_turns: 60
timeout_seconds: 1800
allowed_tools: [Read, Glob, Grep, Skill, Agent, ToolSearch, WebSearch, WebFetch]
---

/myspec:research for integration tests in our PHP/Symfony monorepo on GitHub Actions, should we use Testcontainers (testcontainers-php) or plain docker compose services? we need MySQL 8 and RabbitMQ, ~1500 tests, CI time matters.
