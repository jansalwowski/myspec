---
title: "Ideas Management"
purpose: "Ideas pipeline from raw ideas to feature documentation"
paths:
  - ${aiDir}/ideas/**
updated: 2026-09-03
---

# Ideas Management

`${aiDir}/ideas/` holds raw feature ideas before they become specs. The instruction docs live in the directory itself:

- New idea → `${aiDir}/ideas/INTAKE-INSTRUCTIONS.md` (analyze + queue), or `/myspec:idea-intake`
- What's next → `${aiDir}/ideas/PRIORITY-LISTING.md` (priorities + dependencies)
- Idea → feature docs → `${aiDir}/ideas/PROCESSING-INSTRUCTIONS.md`, or `/myspec:idea-process`; done ideas move to `${aiDir}/ideas/processed/`
