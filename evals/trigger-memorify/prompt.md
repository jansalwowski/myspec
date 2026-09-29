---
description: "The user asks what from the conversation is worth keeping: memorify (sweep), not memorize (named fact) or session-complete (wrap-up)."
tags: [skill:memorify, skill:memorize, skill:session-complete, trigger, regression]
max_turns: 6
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill]
---

We just spent the afternoon on the flaky invoice PDF test. It only failed when the machine's timezone wasn't UTC, because the due-date formatter used local time; pinning TZ=UTC in the test runner fixed it. Along the way we also found that the PDF library silently drops fonts it can't embed. Anything from this debugging worth keeping?
