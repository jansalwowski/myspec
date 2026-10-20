---
description: "A diagram to look at, no decision to submit: visualize-options (show mode), not brainstorm."
tags: [skill:visualize-options, skill:brainstorm, trigger, capability]
max_turns: 2
runs: 1
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill]
---

For the invoice export we have two designs on the table: the API puts a job on a queue and a worker writes the file to storage, or the API streams the file directly and the client retries on failure. Draw both architectures next to each other in my browser so I can see how the pieces connect.
