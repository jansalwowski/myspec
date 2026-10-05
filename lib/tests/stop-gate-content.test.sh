#!/usr/bin/env bash
# Function tests for lib/stop-gate/content.sh (R14, #263): which lines a Bash
# write added (numbered from the hunk headers), which of them the file still
# holds, the content before a write (a snapshot blob, a copy kept outside a
# read-only object store, no file, or HEAD's version when no snapshot was
# taken), and which roots the content gates own.
# The gate end to end: hooks/tests/verify-before-stop-content.test.sh.
#
# Usage: stop-gate-content.test.sh

set -uo pipefail

LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/hook-core.sh
. "$LIB/hook-core.sh"
# shellcheck source=lib/session-event.sh
. "$LIB/session-event.sh"
# shellcheck source=lib/content-checks.sh
. "$LIB/content-checks.sh"
# shellcheck source=lib/stop-gate/arm.sh
. "$LIB/stop-gate/arm.sh"
# shellcheck source=lib/stop-gate/content.sh
. "$LIB/stop-gate/content.sh"

ROOT=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }
expect() {  # expect <want> <got> <desc>
  if [ "$1" = "$2" ]; then ok; else fail "$3 (want: $1; got: $2)"; fi
}

REPO="$ROOT/repo"
mkdir -p "$REPO/docs"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
OUT="$ROOT/out"

# --- added_lines: the `+` lines of before -> after, numbered in after ----------
printf 'one\ntwo\n' > "$ROOT/before"
printf 'zero\none\ntwo-edited\nthree\n' > "$ROOT/after"
added_lines "$ROOT/before" "$ROOT/after" "$OUT"
expect "1	zero
3	two-edited
4	three" "$(cat "$OUT")" "added lines carry their line numbers across several hunks"

added_lines "$ROOT/before" "$ROOT/before" "$OUT"
expect "" "$(cat "$OUT")" "an unchanged file adds nothing"

printf 'one\n+++ not a header\n' > "$ROOT/after"
added_lines "$ROOT/before" "$ROOT/after" "$OUT"
expect "2	+++ not a header" "$(cat "$OUT")" "a body line starting with +++ is content"

: > "$ROOT/empty"
added_lines "$ROOT/empty" "$ROOT/before" "$OUT"
expect "1	one
2	two" "$(cat "$OUT")" "from nothing, every line"

# --- session_lines: the lines the file still holds -----------------------------
printf '5\tadded\n9\tgone\n' > "$ROOT/session-added"
printf 'old\nadded\nother\n' > "$ROOT/now"
session_lines "$ROOT/now" "$ROOT/session-added" "$OUT"
expect "2	added" "$(cat "$OUT")" "a line the session added is judged where it is now; one removed since is not"
printf '1\tadded\n' > "$ROOT/session-added"
printf 'old\r\nadded\r\n' > "$ROOT/now"
session_lines "$ROOT/now" "$ROOT/session-added" "$OUT"
expect "2	added" "$(cat "$OUT")" "a CRLF line matches the added text git normalised to LF"
printf '1\tadded\r\n' > "$ROOT/session-added"
printf 'added\n' > "$ROOT/now"
session_lines "$ROOT/now" "$ROOT/session-added" "$OUT"
expect "1	added" "$(cat "$OUT")" "an LF line matches added text that kept its CR"

# --- content_before: the blob, nothing, or HEAD's version ------------------------
printf 'one\ntwo\n' > "$REPO/docs/a.md"
content_before "$REPO" docs/a.md "?" "$OUT"
expect 1 "$CONTENT_NEW" "no snapshot on an unborn branch: no file before"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m init
printf 'uncommitted\n' > "$REPO/docs/a.md"
content_before "$REPO" docs/a.md "?" "$OUT"
expect "0 one
two" "$CONTENT_NEW $(cat "$OUT")" "no snapshot: HEAD's version"
content_before "$REPO" docs/a.md @ "$OUT"
expect "0 one
two" "$CONTENT_NEW $(cat "$OUT")" "@ (the previous write was not hashed): HEAD's version"
content_before "$REPO" docs/a.md - "$OUT"
expect "1 " "$CONTENT_NEW $(cat "$OUT")" "- : there was no file"
BLOB=$(git -C "$REPO" hash-object -w -- docs/a.md)
content_before "$REPO" docs/a.md "$BLOB" "$OUT"
expect "0 uncommitted" "$CONTENT_NEW $(cat "$OUT")" "a blob: its content"
content_before "$REPO" docs/a.md 0000000000000000000000000000000000000000 "$OUT" && fail "a blob git does not have fails" || ok
git -C "$REPO" checkout -q -- docs/a.md

# --- content_snapshot: a blob, or a copy kept outside a read-only store ----------
STATE_HOME="$REPO" SESSION_ID="sgc-kept"
printf 'kept\r\n' > "$REPO/docs/k.md"
KEPT=$(session_keep "$STATE_HOME" "$SESSION_ID" "$REPO" docs/k.md)
case "$KEPT" in kept:*) ok ;; *) fail "session_keep names the copy (got: $KEPT)" ;; esac
rm -f "$REPO/docs/k.md"
CONTENT_KEPT=0
content_snapshot "$REPO" "$KEPT" "$OUT"
expect "1 kept" "$CONTENT_KEPT $(tr -d '\r' < "$OUT")" "kept:<id>: the copy, flagged as kept"
CONTENT_KEPT=0
content_before "$REPO" docs/k.md "$KEPT" "$OUT"
expect "0 1" "$CONTENT_NEW $CONTENT_KEPT" "content_before reads a kept copy"
content_snapshot "$REPO" kept:def456 "$OUT" && fail "a kept copy that is gone fails" || ok
content_snapshot "$REPO" "kept:../${KEPT#kept:}" "$OUT" && fail "a kept id that is not hex fails" || ok
CONTENT_KEPT=0
content_snapshot "$REPO" "$BLOB" "$OUT"
expect "0 uncommitted" "$CONTENT_KEPT $(cat "$OUT")" "a blob is not flagged as kept"

# --- content_root_ok -----------------------------------------------------------
arm_init "$REPO"
content_root_ok "$REPO" && ok || fail "the cwd's root is owned"
WT="$ROOT/wt"
git -C "$REPO" worktree add -q -b wt "$WT" main
content_root_ok "$WT" && ok || fail "a linked worktree of the repository is owned"
OTHER="$ROOT/other"
mkdir -p "$OTHER" && git init -q -b main "$OTHER"
content_root_ok "$OTHER" && fail "another repository is not owned" || ok
NESTED="$REPO/vendor/nested"
mkdir -p "$NESTED" && git init -q -b main "$NESTED"
content_root_ok "$NESTED" && ok || fail "a checkout nested in the cwd's tree is owned"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
