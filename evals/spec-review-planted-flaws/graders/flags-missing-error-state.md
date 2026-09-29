---
type: llm
---

PASS if the review points out that the spec does not define what happens when the export cannot produce a normal file: for example a failed export or error, or a date range that contains no invoices (empty result), or an invalid date range (end before start).
FAIL if none of these missing failure/empty/invalid-input states is mentioned.
