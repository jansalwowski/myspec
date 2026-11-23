# Paid Checks

Read from implementer-prompt.md, probe-gate.md and completion.md when a task's `Verify at phase review:` command or a checkpoint probe starts model sessions.

A paid check is a command that starts model sessions or calls a model API: an eval harness such as `claude plugin eval`, an LLM-judged test, a script that prompts a model. Each run costs money, takes minutes, and can give a different result with no code change. Cost grows with cases × runs × arms, and tools default to several runs per case, so one suite can cost tens of dollars. No subagent runs one, and nothing runs one without the user's yes:

- **Dispatch.** When a task's `Verify at phase review:` command is a paid check (older plans), put `none` in its place in the implementer prompt and the workflow `verifyCommand` (the phase reviewer's prompt already forbids running one), and log `Ruling: Task N Verify is a paid check, held for the user — cost if wrong: the eval is unproven until the user runs it`. The same holds in every fix round.
- **Probe.** A checkpoint probe that is a paid check is never dispatched without asking: [probe-gate.md](probe-gate.md#paid-probes).
- **Approved run.** Use the narrowest form the tool offers (one case, one run, no baseline arm, a cost ceiling), and log the command and the reported cost in the Execution Log.
- **Report.** Every held paid check is listed in the completion report with its command, so the user can run it or leave it to CI.

