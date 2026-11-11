---
type: regex
flags: im
pattern: '^\|\s*\**Critical\**\s*\|(?!\s*\**(?:0|none|n/a|—|-|high|medium|low)\**\s*(?:\||$))|\b[1-9]\d* Critical\b|^#{1,4} [^\n]*Critical[^\n]*\n+\s*(?!none\b|n/a\b|-\s*none\b|—)\S'
---
