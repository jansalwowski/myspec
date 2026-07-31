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

# Anti-Pattern #13 — all-caps imperative density
# Count occurrences of \b(MUST|ALWAYS|NEVER|SHOULD NOT|DO NOT)\b
# Flag if >5 occurrences without nearby rationale ("because", "since", "to avoid")

# Anti-Pattern #14 — model-known explanations
# Heuristic: paragraphs that define common terms or explain mainstream libraries
/\b(is a popular|is a JavaScript library|allows you to|is used to)\b/i

# Manual-only invocation (skip Anti-Pattern #1 and "Use when" check)
/^disable-model-invocation:\s*true/m

# Oversized code blocks (flag if > 20 lines between ``` markers)
```
