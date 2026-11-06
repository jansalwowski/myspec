#!/usr/bin/env bash
# Regression fixture for YAML comments in memory frontmatter (#393).
#
# memory-files.mjs read the rest of a field's line as its value, comment and
# all: `related: [] # (e.g., ["P009"])` gave three junk IDs, a trailing
# comment on `anchors: []` gave an anchor on a file named `path`, and one on
# `hook:` reached the index row. The doctor, memory-index.mjs and the
# claim script all read through memory-files.mjs, so this checks the parser
# and then the index row end to end.
#
# Usage: memory-files-comments.test.sh [path-to-repo-root]

set -uo pipefail

REPO_ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
FILES="$REPO_ROOT/lib/memory-files.mjs"
INDEX="$REPO_ROOT/lib/memory-index.mjs"
SCAFFOLD="$REPO_ROOT/scaffolding/memory"

for path in "$FILES" "$INDEX" "$SCAFFOLD"; do
  if [ ! -e "$path" ]; then
    echo "FATAL: not found: $path" >&2
    exit 1
  fi
done

ROOT=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0

# expect <description> <want> <frontmatter> <js expression over fm>
expect() {
  local got
  got=$(FM="$3" node --input-type=module -e "
    import * as m from '$FILES';
    const fm = process.env.FM;
    console.log(JSON.stringify($4));
  " 2>&1)
  if [ "$got" = "$2" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL  %s\n      got:  %s\n      want: %s\n' "$1" "$got" "$2" >&2
  fi
}

# ------------------------------------------------------------ parser

expect "related flow list drops its trailing comment" '[]' \
  'related: []         # IDs of related memories (e.g., ["P009"])' \
  "m.listField(fm, 'related')"

expect "related items survive a trailing comment" '["P001","S002"]' \
  'related: [P001, "S002"]  # see both' \
  "m.listField(fm, 'related')"

expect "block list item drops its trailing comment" '["P001"]' \
  "$(printf 'related:\n  - P001  # the first one')" \
  "m.listField(fm, 'related')"

expect "hook ending in a comment" '"cache, flush"' \
  'hook: "cache, flush"   # keywords only' \
  "m.scalarField(fm, 'hook')"

expect "unquoted hook ending in a comment" '"cache, flush"' \
  'hook: cache, flush # keywords only' \
  "m.scalarField(fm, 'hook')"

expect "a # inside a quoted value is kept" '"issue # 12, retry"' \
  'hook: "issue # 12, retry"  # note' \
  "m.scalarField(fm, 'hook')"

expect "a # inside a single-quoted value is kept" "\"it's # one\"" \
  "hook: 'it''s # one'  # note" \
  "m.scalarField(fm, 'hook')"

expect "a # with no whitespace before it is kept" '"C#, F#"' \
  'hook: C#, F# # languages' \
  "m.scalarField(fm, 'hook')"

expect "a value that is only a comment is empty" '""' \
  'hook: # fill in' \
  "m.scalarField(fm, 'hook')"

expect "anchors [] with a trailing comment is empty" '{"anchors":[],"form":"empty","malformed":[]}' \
  'anchors: []         # [{file: "path", pattern: "regex"}]' \
  "m.parseAnchors(fm)"

expect "anchor pattern keeps a quoted #, drops the comment" '[{"file":"src/a.c","pattern":"^#include"}]' \
  "$(printf 'anchors:\n  - file: src/a.c  # header\n    pattern: \"^#include\"  # first line')" \
  "m.parseAnchors(fm).anchors"

expect "flow anchor list drops its trailing comment" '[{"file":"x","pattern":"y"}]' \
  'anchors: [{file: "x", pattern: "y"}]  # [{file: "path", pattern: "z"}]' \
  "m.parseAnchors(fm).anchors"

# ------------------------------------------------------------ end to end

REPO="$ROOT/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q .
printf '{ "aiDir": ".ai" }\n' > "$REPO/.myspec.json"
for kind in procedural semantic episodic; do
  mkdir -p "$REPO/.ai/memory/$kind"
  cp "$SCAFFOLD/$kind/index.md" "$REPO/.ai/memory/$kind/index.md"
done
cat > "$REPO/.ai/memory/procedural/P001-cache.md" <<'EOF'
---
id: P001
type: procedural
hook: "cache, flush — keyword summary"   # never the solution
created: 2026-01-01
anchors: []         # [{file: "path", pattern: "regex"}]
related: []         # (e.g., ["P009"])
---

# Cache flush
EOF

out=$(cd "$REPO" && node "$INDEX" 2>&1)
row=$(grep -F 'P001' "$REPO/.ai/memory/procedural/index.md")
case "$row" in
  *"| cache, flush — keyword summary | --- |"*) PASS=$((PASS + 1)) ;;
  *) FAIL=$((FAIL + 1)); printf 'FAIL  index row carries the hook without its comment, and no anchor\n      %s\n      %s\n' "$row" "$out" >&2 ;;
esac

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
