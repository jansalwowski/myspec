---
type: tool_used
tool: Bash
input_match: 'aidir-render\.mjs\S*\s+\S*framework-files/rules/paths\.md'
min: 1
---

The run rendered rules/paths.md through the plugin's renderer, the only
renderer that keeps its `$${aiDir}` row a literal `${aiDir}` (#464). The
installed file itself cannot be graded: the eval sandbox refuses every write
under `.claude/`, from Bash and the Write tool alike.
