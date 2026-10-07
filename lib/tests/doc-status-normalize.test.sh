#!/usr/bin/env bash
# Tests for lib/doc-status-normalize.mjs, the 3.1.0-doc-status migration
# (#261): complete/implemented -> approved and superseded -> deprecated in
# spec.md / tech-spec.md frontmatter, every other off-vocabulary value
# reported and left alone, only the status: line touched, idempotent.
#
# Usage: doc-status-normalize.test.sh [path-to-script]

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${1:-$HERE/../doc-status-normalize.mjs}"

if [ ! -f "$SCRIPT" ]; then
  echo "FATAL: script not found: $SCRIPT" >&2
  exit 1
fi

ROOT=$(cd "$(mktemp -d)" && pwd -P)
REPO="$ROOT/proj"
F="$REPO/ai/features"
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

expect_line() {     # expect_line <regex> <description>
  if grep -Eq -- "$1" <<<"$OUTPUT"; then ok; else fail "$2 (no line matching: $1)"; fi
}
expect_no_line() {  # expect_no_line <regex> <description>
  if grep -Eq -- "$1" <<<"$OUTPUT"; then fail "$2 (unexpected line matching: $1)"; else ok; fi
}
expect_file() {     # expect_file <path> <expected content> <description>
  if [ "$(cat "$1")" = "$2" ]; then ok; else fail "$3 (got: $(cat "$1"))"; fi
}

run() { OUTPUT=$(cd "$REPO" && node "$SCRIPT" "$@" 2>&1); STATUS=$?; }

doc() {             # doc <path> <status line>
  mkdir -p "$(dirname "$1")"
  printf -- '---\ntitle: "x"\n%s\nspec_version: 1\n---\n\n# Doc\n\nstatus: complete\n' "$2" > "$1"
}

mkdir -p "$F"
printf '{"aiDir":"ai"}\n' > "$REPO/.myspec.json"

doc "$F/shipped/spec.md" 'status: complete'
doc "$F/shipped/tech-spec.md" 'status: "implemented" # flipped by hand'
doc "$F/parent/child/spec.md" "status: 'superseded'"
doc "$F/fine/spec.md" 'status: approved'
doc "$F/odd/spec.md" 'status: shipped'
doc "$F/odd/tech-spec.md" 'status: Complete'
mkdir -p "$F/crlf"
printf -- '---\r\ntitle: x\r\nstatus: complete\r\n---\r\n\r\n# Doc\r\n' > "$F/crlf/spec.md"
# Not frontmatter, not a doc file, not a frontmatter status line.
mkdir -p "$F/nofm" "$F/shipped/plans"
printf '# Spec\n\nstatus: complete\n' > "$F/nofm/spec.md"
doc "$F/shipped/plans/2026-01-01-plan.md" 'status: superseded'
doc "$F/shipped/dependencies.md" 'status: complete'
printf -- '---\ntitle: x\nmeta:\n  status: complete\n---\n' > "$F/fine/tech-spec.md"

BEFORE_OFF=$(cat "$F/odd/spec.md")

# ═══ dry run writes nothing ══════════════════════════════════════════════════

run --dry-run
[ "$STATUS" -eq 0 ] && ok || fail "dry run exits 0 (got $STATUS)"
expect_line '^would rewrite: ai/features/shipped/spec.md  status: complete -> approved$' "dry run names the rewrite"
expect_line 'dry run, nothing written' "dry run says so"
if grep -q '^status: complete$' "$F/shipped/spec.md"; then ok; else fail "dry run leaves the file unchanged"; fi

# ═══ the rewrite ═════════════════════════════════════════════════════════════

run
[ "$STATUS" -eq 0 ] && ok || fail "exits 0 (got $STATUS)"
expect_line '^rewrote: ai/features/shipped/spec.md  status: complete -> approved$' "complete becomes approved"
expect_line '^rewrote: ai/features/shipped/tech-spec.md  status: implemented -> approved$' "implemented becomes approved"
expect_line '^rewrote: ai/features/parent/child/spec.md  status: superseded -> deprecated$' "superseded becomes deprecated, nested sub-feature included"
expect_line '^rewrote: ai/features/crlf/spec.md' "a CRLF doc is rewritten"
expect_line '^off-vocabulary: ai/features/odd/spec.md  status: shipped ' "an unknown value is reported"
expect_line '^off-vocabulary: ai/features/odd/tech-spec.md  status: Complete ' "the mapping is case-sensitive: Complete is reported, not rewritten"
expect_no_line 'fine/|nofm/|plans/|dependencies.md' "approved docs, docs without frontmatter, plans and other files are not touched or reported"
expect_line '^doc-status-normalize: 4 rewritten, 2 off-vocabulary, 9 doc\(s\) checked$' "summary counts"

expect_file "$F/shipped/spec.md" "$(printf -- '---\ntitle: "x"\nstatus: approved\nspec_version: 1\n---\n\n# Doc\n\nstatus: complete')" \
  "only the frontmatter status line changes; a body line that looks like one stays"
if grep -qx 'status: "approved" # flipped by hand' "$F/shipped/tech-spec.md"; then ok; else fail "quotes and trailing comment are kept"; fi
if grep -qx "status: 'deprecated'" "$F/parent/child/spec.md"; then ok; else fail "single quotes are kept"; fi
if [ "$(grep -c $'\r$' "$F/crlf/spec.md")" -eq 6 ] && grep -q $'^status: approved\r$' "$F/crlf/spec.md"; then ok; else fail "CRLF line endings are kept"; fi
expect_file "$F/odd/spec.md" "$BEFORE_OFF" "an off-vocabulary doc is not rewritten"
if grep -q '^status: superseded$' "$F/shipped/plans/2026-01-01-plan.md"; then ok; else fail "an archived plan's superseded status is not touched"; fi
if grep -q '^  status: complete$' "$F/fine/tech-spec.md"; then ok; else fail "a nested status: key is not touched"; fi

# ═══ idempotent ══════════════════════════════════════════════════════════════

SNAP=$(cd "$F" && find . -type f -exec cksum {} + | sort)
run
expect_line '^doc-status-normalize: 0 rewritten, 2 off-vocabulary' "a second run rewrites nothing"
[ "$SNAP" = "$(cd "$F" && find . -type f -exec cksum {} + | sort)" ] && ok || fail "a second run changes no file"

# ═══ no features directory, usage ════════════════════════════════════════════

EMPTY="$ROOT/empty"
mkdir -p "$EMPTY"
OUTPUT=$(cd "$EMPTY" && node "$SCRIPT" 2>&1); STATUS=$?
[ "$STATUS" -eq 0 ] && ok || fail "no features directory exits 0 (got $STATUS)"
expect_line '0 rewritten, 0 off-vocabulary, 0 doc' "no features directory reports nothing"

run --bogus
[ "$STATUS" -eq 2 ] && ok || fail "an unknown flag exits 2 (got $STATUS)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
