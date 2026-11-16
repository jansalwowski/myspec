# Structure Rules

Read by skill-verify step 8.

| Element | Required | Check |
|---------|----------|-------|
| Procedural body | Yes | Numbered steps or an explicit decision table — not prose exposition |
| Rules/Constraints section | Yes | H2 with "Rules", "Constraints", "Common Mistakes", or "Edge Cases" |
| Verification Checklist | Yes | H2 "Verification" with `- [ ]` items |
| Imperative language | Yes | Steps start with: Check, Run, Read, Verify, Create, Add, Remove |
| No documentary language | Yes | Absent: "You should", "It's important to", "Make sure you", "Understanding" |
| Code examples | Recommended | Each block under 20 lines; non-obvious patterns only |

**Match prescriptiveness to the task, do not impose it.** A numbered workflow is right for a narrow task with a known-good path and real hazards. For open-ended tasks it is a defect in its own right — an over-prescribed sequence stops the agent adapting, and rigid step lists are among the most common smells in real skills. Judge the body against the task: flag missing structure only where the task has one correct order. Where it does not, require an explicit decision table instead of a step list.
