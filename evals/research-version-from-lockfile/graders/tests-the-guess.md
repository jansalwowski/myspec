---
type: llm
focus: trace
---

PASS if the final reply treats the redelivery-timeout guess as one candidate and gives at least one other cause of duplicate processing (for example the acknowledgement or row delete failing after the handler ran, or a worker killed mid-handler).
FAIL if the reply only confirms the timeout guess.
