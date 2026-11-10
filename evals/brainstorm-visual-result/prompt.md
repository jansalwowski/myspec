---
description: "Once brainstorm runs on a spike that produced images, it shows them in Visual Buddy or offers it, instead of only pointing at the file paths (#359). The prompt starts the skill by its command, so this grades the offer, not routing; trigger-brainstorm grades routing (#410)."
tags: [skill:brainstorm, capability]
runs: 1
max_turns: 6
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill]
---

/myspec:brainstorm I ran the first experiment on anonymising licence plates in our street photos; the two renders are in spike/out/ (spike/NOTES.md says what each one is). Before we commit to either, I want to widen the options: what else could we try besides blur and pasted crops? Throw out a few directions, then poke holes in whichever looks strongest.
