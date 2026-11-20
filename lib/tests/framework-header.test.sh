#!/usr/bin/env bash
# Tests for lib/framework-header.mjs (#545): the later of the framework's and
# the project's `updated:` date in a marker-merge header. The read side
# (withShippedDate) is what the doctor and pin-reconcile compare through;
# the write side (the keep-date CLI) is what update's marker-merge step
# writes. Both read frontmatter through lib/markdown.mjs.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB="$(cd "$HERE/.." && pwd)"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

# same <installed> <shipped>: withShippedDate(installed, shipped) === shipped,
# the doctor's "no drift".
same() {
  FH_A="$1" FH_B="$2" node --input-type=module -e '
import { withShippedDate } from "'"$LIB"'/framework-header.mjs";
const { FH_A: a, FH_B: b } = process.env;
process.exit(withShippedDate(a, b) === b ? 0 : 1);'
}
yes() { if same "$1" "$2"; then ok; else fail "$3"; fi; }
no()  { if same "$1" "$2"; then fail "$3"; else ok; fi; }

SHIPPED=$'---\ntitle: T\nupdated: 2026-11-15\n---\n\n# H'
later() { printf '%s' "${SHIPPED/2026-11-15/$1}"; }
BOM=$'\xef\xbb\xbf'
crlf() { printf '%s' "${1//$'\n'/$'\r\n'}"; }

yes "$(later 2026-11-20)" "$SHIPPED" "a later date is not drift"
yes "$SHIPPED" "$SHIPPED" "an equal date is not drift"
no "$(later 2026-11-01)" "$SHIPPED" "an earlier date is drift"
no "$(later 2026-99-99)" "$SHIPPED" "a month 99 date is drift, not later"
no "$(later 2026-11-31)" "$SHIPPED" "November 31 is drift, not later"
yes "$(later '2026-11-20 # project section')" "$SHIPPED" "a later date with a trailing comment is not drift"
no "$(later '2026-11-20#x')" "$SHIPPED" "a # with no space before it is part of the value, so drift"
yes "$BOM$(later 2026-11-20)" "$BOM$SHIPPED" "a BOM before the frontmatter is read (lib/markdown.mjs rule)"
yes "$(crlf "$(later 2026-11-20)")" "$(crlf "$SHIPPED")" "a CRLF header with a later date is not drift"

# --- write side: keep-date ----------------------------------------------------
printf '%s\n' "$SHIPPED" > "$ROOT/source.md"
keep() { node "$LIB/framework-header.mjs" keep-date "$1" < "$ROOT/source.md"; }

later '2026-11-20 # project section' > "$ROOT/dest.md"
OUT=$(keep "$ROOT/dest.md"); RC=$?
[ "$RC" -eq 0 ] && ok || fail "keep-date exits 0 (rc=$RC)"
printf '%s\n' "$OUT" | grep -qx 'updated: 2026-11-20 # project section' && ok || fail "keep-date writes a later destination date (got: $OUT)"
[ "$(printf '%s\n' "$OUT" | grep -vx 'updated: 2026-11-20 # project section')" = "$(printf '%s\n' "$SHIPPED" | grep -vx 'updated: 2026-11-15')" ] && ok || fail "keep-date keeps the rest of the source"
# What update writes, the doctor reads back as no drift.
yes "$OUT" "$SHIPPED" "the written header passes the doctor's comparison"

later 2026-11-01 > "$ROOT/dest.md"
[ "$(keep "$ROOT/dest.md")" = "$SHIPPED" ] && ok || fail "an earlier destination date is replaced by the source's"
later 2026-99-99 > "$ROOT/dest.md"
[ "$(keep "$ROOT/dest.md")" = "$SHIPPED" ] && ok || fail "an impossible destination date is replaced by the source's"
[ "$(keep "$ROOT/missing.md")" = "$SHIPPED" ] && ok || fail "a missing destination leaves the source as it is"
node "$LIB/framework-header.mjs" bogus < /dev/null >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && ok || fail "an unknown command is a usage error (rc=$RC)"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
