---
description: "feature-mockup --explore on a brief-stage spec writes rough wireframe variants, at least one labelled as an exploration, to the feature's exploration/ folder only: nothing in mockups/, and spec.md keeps `stage: brief`. The prompt starts the skill by its command, so this grades explore mode, not routing."
tags: [skill:feature-mockup, capability]
runs: 1
max_turns: 16
timeout_seconds: 480
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit]
---

/myspec:feature-mockup --explore invoice-reminders

Sketch two or three rough layouts for the screen where the owner turns reminders on or off per customer. I don't know yet whether it should be a list with toggles or something else. Don't ask me anything; I'll look at them and pick one later.
