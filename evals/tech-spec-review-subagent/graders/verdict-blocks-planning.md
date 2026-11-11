---
type: regex
flags: im
pattern: '^\|\s*\**Critical\**\s*\|(?!\s*\**(?:0\b|none\b|no (?:\w+ )?(?:findings?|issues?)\b|n/a\b|[—–-]+\s*(?:\||$)|(?:high|medium|low)\**\s*(?:\||$)))|^\|\s*\**Critical\**\s*\|[^\n]*\n\|[\s:|-]+\|[ \t]*\n\|\s*\**[1-9]\d*\**\s*\||\b[1-9]\d* Critical\b|^#{1,4} [^\n]*Critical[^\n]*\n+\s*(?!none\b|n/a\b|-\s*none\b|—)\S'
---
