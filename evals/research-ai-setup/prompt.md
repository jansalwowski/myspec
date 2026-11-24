---
description: "Once research runs on a Claude Code setup question, it cites the official docs and treats which option works best as a hypothesis with a concrete test."
tags: [skill:research, capability]
runs: 1
max_turns: 60
timeout_seconds: 1800
allowed_tools: [Read, Glob, Grep, Skill, Agent, ToolSearch, WebSearch, WebFetch]
---

/myspec:research I want subagents in Claude Code to follow my project conventions more reliably. Which works best: rules in CLAUDE.md, preloading skills via the agent's frontmatter, or enforcing with hooks?
