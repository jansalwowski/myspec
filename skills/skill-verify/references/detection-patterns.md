# Detection Patterns

Regexes and heuristics for skill-verify step 5 (anti-pattern scan) and step 4 (frontmatter validation).

```
# name format (frontmatter)
/^[a-z0-9-]{1,64}$/

# description starts with "Use when"
/^Use when/

# Anti-Pattern #1 — workflow in description (sequential action verbs)
/\b(analyzes?|generates?|creates?|validates?|checks?)\b.*(then|next|after|finally)/i

# Anti-Pattern #3 — README-style language
/This skill (helps|is|provides|enables)|Understanding .* is important/i

# Anti-Pattern #5 — first/second person
/\b(I can|I will|you should|you can|your |we |our |my )\b/i

# Anti-Pattern #9 — force-loading
/@[a-zA-Z][\w\/.-]+/

# Documentary language in steps
/\b(You should|It's important to|Make sure you|Remember to)\b/

# Anti-Pattern #10 — no progressive disclosure (>300 lines with inlined refs)
# Count body lines; if >300, scan for tables/examples that are only used in one step

# Anti-Pattern #8 extended — no conditional branching
# Check workflow section for absence of: if, when, unless, otherwise
/\b(if |when |unless |otherwise)\b/i

# Anti-Pattern #12 — decorative formatting
/^>\s*(\*\*)?Note[:\*]/m              # blockquote "Note:" boxes
/^---\s*$/m                            # horizontal rules inside body (not frontmatter)
/^#{1,6}\s+[\u{1F300}-\u{1FAFF}]/mu    # emoji-prefixed headers
/^\s{6,}[-*]\s/m                       # 3-deep (or deeper) bullet ladders

# Anti-Pattern #12 — post-invocation persuasion sections
/^#{2,4}\s+(The\s+)?(Bottom Line|Remember|Key Principles|Why (This|It) Matters|Benefits)\b/mi
# Also: paragraphs of social proof ("teams report", "proven to", "saves hours") anywhere in body

# Anti-Pattern #13 — all-caps imperative density
# Count occurrences of \b(MUST|ALWAYS|NEVER|SHOULD NOT|DO NOT)\b
# Flag if >5 occurrences without nearby rationale ("because", "since", "to avoid")

# Anti-Pattern #14 — model-known explanations
# Heuristic: paragraphs that define common terms or explain mainstream libraries
/\b(is a popular|is a JavaScript library|allows you to|is used to)\b/i

# Anti-Pattern #15 — guidance form mismatch (heuristics; classify the targeted failure first, then check form)
# Prohibition cluster aimed at output shape: 3+ consecutive bullets matching, with no positive
# recipe (numbered parts, "The output is...") nearby:
/^\s*[-*]\s*(Don'?t|Do not|Never|Avoid)\b/m
# Soft wording on a discipline rule (rule framed with pressure/red-flag language but hedged verbs):
/\b(prefer|consider|try to|ideally|where possible)\b/i
# Prose reminder near a template: paragraph within ~5 lines of a template block restating a field
# the template itself should mark REQUIRED

# Anti-Pattern #16 — nuance and exemption clauses
/\bunless (it|this|that)?\s?(matters|necessary|needed|important|makes sense)\b/i
/\bexcept (when|if|where) (necessary|needed|it matters|appropriate)\b/i
/\b(doesn'?t|does not) apply (to|when|if)\b/i
# Scope: flag only hedges appended to a rule/prohibition/limit whose predicate is a judgment call.
# Workflow branching on observable predicates (if/when/unless <checkable condition>) is the RIGHT
# form (see Anti-Pattern #8) — do not flag it.

# Manual-only invocation (skip Anti-Pattern #1 and "Use when" check)
/^disable-model-invocation:\s*true/m

# Oversized code blocks (flag if > 20 lines between ``` markers)
```
