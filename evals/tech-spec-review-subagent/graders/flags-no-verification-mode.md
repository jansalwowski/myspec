---
type: regex
flags: im
pattern: 'medium[^\n]{0,240}verification[_ ]mode|verification[_ ]mode[^\n]{0,240}\bmedium\b|^[ \t]*(#{1,6})[ \t][^\n]*\bmedium\b[^\n]*\n(?:(?![ \t]*(?:(?!\1#)#{1,6}[ \t]|[#|>*_\- \t\d.]*(?:critical|high|low)\b))[^\n]*\n){0,40}?(?![ \t]*(?:(?!\1#)#{1,6}[ \t]|[#|>*_\- \t\d.]*(?:critical|high|low)\b))[^\n]*verification[_ ]mode'
---
