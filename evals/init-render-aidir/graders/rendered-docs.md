---
type: tool_used
tool: Bash
input_match: 'aidir-render\.mjs\S*\s+\S*framework-files/pre-flight\.md'
min: 1
---

The run copied the ${aiDir} documents through the plugin's renderer, the only
one that keeps a `$${aiDir}` escape literal (#464). pre-flight.md is graded,
not rules/paths.md: init writes the rules under `.claude/`, which the eval
sandbox refuses, and in 3 of 3 runs it stopped there before rendering them.
