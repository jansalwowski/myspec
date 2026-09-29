---
type: tool_order
before:
  tool: Agent
  input_match: '(?=[\s\S]*\bTask 1\b)(?=[\s\S]*DONE_WITH_CONCERNS)'
after:
  tool: Write
  input_match: '"file_path"\s*:\s*"(?:[^"]*/)?(?:app|tests)/[^"]*\.py"'
---
