---
type: llm
focus: trace
---

PASS if the session dispatched a verifier agent whose prompt lists claims to check and contains neither a draft answer nor the user's guess that the redelivery timeout is the cause.
FAIL if no verifier agent was dispatched, or its prompt includes the draft answer or states the user's guess.
