#!/usr/bin/env bash
# memory-index --backfill on memories whose frontmatter is not plain LF
# (#429, #434 review): an LF opening with CRLF lines, an all-CRLF file and a
# BOM file each get `hook:` inside their existing block, after `id:`, with
# their line endings and body kept; none gets a second block.
#
# Usage: memory-index-endings.test.sh [path-to-script]

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${1:-$HERE/../memory-index.mjs}"
ROOT=$(cd "$(mktemp -d)" && pwd -P)
REPO="$ROOT/repo"
MEM="$REPO/.ai/memory"
mkdir -p "$MEM/procedural" "$MEM/semantic" "$MEM/episodic"
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n      %s\n' "$1" "${2:-}" >&2; }

cd "$REPO" || exit 1
git init -q .
printf '{ "aiDir": ".ai" }\n' > .myspec.json

for t in procedural semantic episodic; do
  printf -- '---\ntype: %s\nupdated: 2020-01-01\n---\n\n# Index\n\n| ID | Hook | Anchor |\n|----|------|--------|\n' "$t" > "$MEM/$t/index.md"
done
printf '| P001 | mixed endings hook | |\n| P002 | crlf hook | |\n| P003 | bom hook | |\n' >> "$MEM/procedural/index.md"

printf -- '---\nid: P001\r\ntype: procedural\r\ncreated: 2026-05-01\r\n---\r\n\r\n# P001: Mixed\r\n\r\nBody.\r\n' > "$MEM/procedural/P001-mixed.md"
printf -- '---\r\nid: P002\r\ntype: procedural\r\ncreated: 2026-05-01\r\n---\r\n\r\n# P002: Crlf\r\n\r\nBody.\r\n' > "$MEM/procedural/P002-crlf.md"
printf '\xef\xbb\xbf---\nid: P003\ntype: procedural\ncreated: 2026-05-01\n---\n\n# P003: Bom\n\nBody.\n' > "$MEM/procedural/P003-bom.md"

OUT=$(node "$SCRIPT" --backfill 2>&1); CODE=$?
[ "$CODE" = 0 ] && ok || fail "--backfill exits 0" "$OUT"

expect_bytes() {    # expect_bytes <file> <printf format of the whole file> <description>
  local want
  # shellcheck disable=SC2059 # the argument is a printf format by design
  want=$(printf -- "$2" | od -An -c)
  if [ "$(od -An -c < "$1")" = "$want" ]; then ok; else fail "$3" "$(od -c < "$1" | head -12)"; fi
}

# shellcheck disable=SC2016 # printf formats, not expansions
expect_bytes "$MEM/procedural/P001-mixed.md" '---\nid: P001\r\nhook: "mixed endings hook"\r\ntype: procedural\r\ncreated: 2026-05-01\r\n---\r\n\r\n# P001: Mixed\r\n\r\nBody.\r\n' "LF opening, CRLF lines: hook after id, body kept"
expect_bytes "$MEM/procedural/P002-crlf.md" '---\r\nid: P002\r\nhook: "crlf hook"\r\ntype: procedural\r\ncreated: 2026-05-01\r\n---\r\n\r\n# P002: Crlf\r\n\r\nBody.\r\n' "CRLF file: hook inside the block with a CRLF ending"
expect_bytes "$MEM/procedural/P003-bom.md" '\357\273\277---\nid: P003\nhook: "bom hook"\ntype: procedural\ncreated: 2026-05-01\n---\n\n# P003: Bom\n\nBody.\n' "BOM file: BOM kept, hook inside the block"

OUT=$(node "$SCRIPT" --check 2>&1); CODE=$?
[ "$CODE" = 0 ] && ok || fail "--check is clean after the backfill" "$OUT"

printf '\nmemory-index-endings: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
