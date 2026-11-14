---
description: "A fresh /myspec:init with every answer given up front must copy the ${aiDir} documents through lib/aidir-render.mjs (graded on pre-flight.md), the renderer that keeps a `$${aiDir}` escape literal (#464); a sed or a hand substitution does not. rules/paths.md is not graded: init writes it under .claude/, which the eval sandbox refuses."
tags: [skill:init, artifact-contract, capability]
runs: 1
max_turns: 100
timeout_seconds: 1500
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit, Bash]
---

/myspec:init Set myspec up in this repo. Here are all the answers so you don't need to ask me anything: project name billing-app; tech stack Python 3.12, Flask, PostgreSQL; AI docs directory `.ai`; lint `ruff check .`, no type-check, tests `pytest`; yes to the harness config. Skip the blueprint offers. Run each shell command on its own: chained commands are blocked here.
