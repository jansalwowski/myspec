---
description: "The user asks brainstorm which of two existing renders looks less fake. It offers Visual Buddy for them instead of reading the images itself and describing them in words: a visual result the user brought counts, not only one the agent produced. The prompt starts the skill by its command, so this grades the offer, not routing."
tags: [skill:brainstorm, capability]
runs: 1
max_turns: 6
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill]
---

/myspec:brainstorm I ran the first experiment on anonymising licence plates in our street photos; the two renders are in spike/out/ (spike/NOTES.md says what each one is). Before we commit to either, I want to widen the options: what else could we try besides blur and pasted crops? Throw out a few directions, then poke holes in whichever looks strongest. And tell me which of the two renders looks less fake to you.
