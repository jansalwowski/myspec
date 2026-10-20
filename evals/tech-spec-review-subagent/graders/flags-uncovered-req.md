---
type: regex
flags: im
pattern: 'REQ-0*4\b[^|\n]*\|\s*(—|–|-{1,3}|none|n/a)\s*\||^(?=[^\n]*REQ-0*4\b)(?=[^\n]*(not covered|uncovered|no (implementation )?steps?\b|missing (implementation|step|coverage)|unmapped|not (addressed|handled|implemented|enforced|mapped)|no [^\n]{0,30}(filter|exclu)|drafts? (would|will|are|could|can|still)\b[^\n]{0,30}(includ|leak|appear|export|slip))).*'
---
