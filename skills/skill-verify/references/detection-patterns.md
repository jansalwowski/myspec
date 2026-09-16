# Detection Patterns

Regexes and heuristics for skill-verify step 5 (frontmatter) and step 6 (anti-pattern scan). Both steps load this file. Judgment-based rows (#4, #14, #15, #16) and every Structural Completeness row have no regex — see `structural-completeness.md`.

```
# name format — spec-exact: no leading/trailing hyphen, no consecutive hyphens,
# and a single character is legal (the alternation is required, not optional)
/^[a-z0-9]$|^[a-z0-9](?:[a-z0-9]|-(?!-)){0,62}[a-z0-9]$/

# name reserved words and XML
/\b(anthropic|claude)\b/i
/<[^>]+>/                              # XML tags in name or description

# description starts with "Use when"
/^Use when/

# allowed-tools type — SPEC/UPLOAD TIER ONLY. Claude Code accepts space-separated,
# comma-separated, and YAML list forms and normalizes all three, so the list form is
# correct for a Claude Code-only skill. Flag only when the spec validator or a
# claude.ai/Skills API upload is a target. Matches both list spellings:
/^allowed-tools:\s*(\[|\n\s*-\s)/m

# invalid invocation combo — nobody can invoke (Critical)
# both present and true/false respectively:
/^disable-model-invocation:\s*true/m   AND   /^user-invocable:\s*false/m

# backslash paths (must be forward slashes even on Windows).
# Requires a drive letter or a real file extension — a naive backslash scan matches
# shell escapes (printf '\n') and regex literals (/\bshould\b/) and has a 0%
# true-positive rate on prose-and-regex-bearing skills.
/(?:^|[\s"'`(=])[A-Za-z]:\\|\\[A-Za-z0-9_-]+\\[A-Za-z0-9_-]+\.[a-z]{1,5}\b/

# Anti-Pattern #1 — workflow in description (sequential action verbs)
/\b(analyzes?|generates?|creates?|validates?|checks?)\b.*(then|next|after|finally)/i

# Anti-Pattern #2 — vague description
/\b(helps with|manages|handles things|deals with|works with)\b/i

# Anti-Pattern #3 — README-style language
/This skill (helps|is|provides|enables)|Understanding .* is important/i

# Anti-Pattern #5 — first/second person
/\b(I can|I will|you should|you can|your |we |our |my )\b/i

# Anti-Pattern #9 — force-loading
/@[a-zA-Z][\w\/.-]+/

# Documentary language in steps
/\b(You should|It's important to|Make sure you|Remember to)\b/

# Anti-Pattern #10 / over-splitting — count body lines; if >300, scan for tables and
# examples consulted in only one step. Inverse check: a references/ file that every
# run loads is indirection with no payoff — propose inlining it.

# Reference depth — file references must stay one level deep from SKILL.md.
# Excludes URL schemes (https:// supplies two separators on its own), ../ sibling
# includes such as ../_shared/review-output.md, and {placeholder} paths inside output
# templates the skill emits (those are not references to bundled files).
/\]\((?!\w+:\/\/)(?!\.\.\/)(?!\.?\/?\{)[^){}]*\/[^){}]*\/[^){}]*\)/
# This is a candidate finder, not a verdict: confirm the target resolves on disk
# relative to the skill root before flagging. A link that does not resolve is either
# template content or a dead link — a different finding, not a depth violation.

# Anti-Pattern #8 — no conditional branching
/\b(if |when |unless |otherwise)\b/i   # absence across the workflow is the flag

# Anti-Pattern #12 — decorative formatting
/^>\s*(\*\*)?Note[:\*]/m               # blockquote "Note:" boxes
/^---\s*$/m                            # horizontal rules inside body (not frontmatter)
/^#{1,6}\s+[\u{1F300}-\u{1FAFF}]/mu    # emoji-prefixed headers
/^\s{6,}[-*]\s/m                       # 3-deep (or deeper) bullet ladders

# Anti-Pattern #12 — post-invocation persuasion sections
/^#{2,4}\s+(The\s+)?(Bottom Line|Remember|Key Principles|Why (This|It) Matters|Benefits)\b/mi
# Also: social proof anywhere in body ("teams report", "proven to", "saves hours")

# Anti-Pattern #13 — unexplained all-caps imperatives
# Count \b(MUST|ALWAYS|NEVER|SHOULD NOT|DO NOT)\b occurrences.
# Flag only those with no rationale within ~2 lines ("because", "since", "to avoid",
# "otherwise"). Caps WITH a stated why are legitimate escalation — do not flag.

# Anti-Pattern #14 — model-known explanations
/\b(is a popular|is a JavaScript library|allows you to|is used to)\b/i

# Anti-Pattern #15 — guidance form mismatch (classify the targeted failure first)
# Prohibition cluster aimed at output shape: 3+ consecutive bullets matching, with no
# positive recipe (numbered parts, "The output is...") nearby:
/^\s*[-*]\s*(Don'?t|Do not|Never|Avoid)\b/m
# Soft wording on a discipline rule (pressure/red-flag framing but hedged verbs):
/\b(prefer|consider|try to|ideally|where possible)\b/i
# Prose reminder within ~5 lines of a template block restating a field the template
# should mark REQUIRED

# Anti-Pattern #16 — nuance and exemption clauses
/\bunless (it|this|that)?\s?(matters|necessary|needed|important|makes sense)\b/i
/\bexcept (when|if|where) (necessary|needed|it matters|appropriate)\b/i
/\b(doesn'?t|does not) apply (to|when|if)\b/i
# Scope: flag only hedges appended to a rule/prohibition/limit whose predicate is a
# judgment call. Workflow branching on observable predicates is the RIGHT form (#8).

# Anti-Pattern #17 — trigger-style description on a manual-only skill
/^disable-model-invocation:\s*true/m   AND   /^description:\s*"?Use when/m

# Anti-Pattern #18 — context: fork with no task
/^context:\s*fork/m
# Then judge: does the body state a task, or only conventions? Conventions-only forks
# return nothing useful.

# Oversized code blocks (flag if > 20 lines between ``` markers)
# Reference files > 100 lines need a table of contents at the top
```

## Character budgets

| Cap | Value | Applies to |
|---|---|---|
| `description` | 1,024 chars | Spec — all targets |
| `description` + `when_to_use` | 1,536 chars combined | Claude Code listing truncation |
| `compatibility` | 500 chars | Spec |
| Body | 5,000 tokens / 500 lines | Past 5,000 the body is truncated on re-injection after `/compact` |

## Spec field set

Exactly six: `name`, `description`, `license`, `compatibility`, `metadata`, `allowed-tools`. Anything else is vendor-specific and is a hard upload failure on claude.ai and the Skills API, not a silent ignore.
