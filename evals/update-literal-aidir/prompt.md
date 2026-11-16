---
description: "A project one release behind holds a rules/paths.md whose 'Framework-managed doc' row was rendered to `.ai/features/foo/spec.md` (#464). /myspec:update must render rules/paths.md through lib/aidir-render.mjs, which keeps the row's literal `${aiDir}`; a hand substitution or a sed loses it. The installed file is not graded: the eval sandbox refuses writes under .claude/."
tags: [skill:update, artifact-contract, capability]
runs: 1
max_turns: 100
timeout_seconds: 1500
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit, Bash]
---

/myspec:update Bring the myspec framework files in this project up to date. Leave the visual-questions setting as it is, and proceed without asking me anything. Run each shell command on its own: chained commands are blocked here.
