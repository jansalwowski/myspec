---
type: llm
---

PASS if the assistant asks the user to choose between the two button labels, "Export CSV" and "Download invoices", and leaves the choice to them, in its reply or through an AskUserQuestion call. A recommendation alongside the question is fine.
FAIL if it picks a label without asking the user to choose, asks only about something else, or never puts the choice to the user.
