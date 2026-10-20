# myspec

myspec is a Claude Code plugin for **specification-driven development** (SDD). You write down what a feature should do and how it will be built, and the coding agent then builds against those documents. Review gates sit between the steps, and hooks check the agent's work.

## Why write the spec first?

A coding agent writes code fast, and it fills every gap in a request with a guess. Most of those guesses are reasonable, and you only find the wrong ones in review, after the code exists. A spec moves those guesses earlier, while they are still a sentence to change:

- **Questions come before code.** Writing the spec forces the agent to ask what persists, what is out of scope, and what counts as done.
- **The documents outlive the session.** The next session, or a teammate, reads `spec.md` instead of reconstructing intent from a diff.
- **Done is checkable.** Acceptance criteria and plan checkboxes give the reviewer something to check the code against.

The cost is a few minutes of questions per feature. For a typo or a one-line fix, skip the pipeline and ask for the change.

## Where to start

<div class="grid cards" markdown>

- **New to myspec?** Install it and ship one small feature: [Quickstart](quickstart.md).
- **Want the whole picture?** See every stage, artifact and gate: [The feature lifecycle](lifecycle.md).
- **Learn by example?** Read a feature delivered from idea to merge: [Full feature delivery](examples/flows/full-feature-delivery.md).

</div>
