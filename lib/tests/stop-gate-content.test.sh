#!/usr/bin/env bash
# Function tests for lib/stop-gate/content.sh (R14, #263): which lines a Bash
# write added and removed (numbered from the hunk headers), which lines the
# session's writes added on net that the file still holds (a revert, a move,
# a second copy, another writer between two writes, #343), the content before a write (a snapshot blob, a copy kept outside a
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

# --- pair_lines: the `+` and `-` lines of before -> after ------------------------
printf 'one\ntwo\n' > "$ROOT/before"
printf 'zero\none\ntwo-edited\nthree\n' > "$ROOT/after"
pair_lines "$ROOT/before" "$ROOT/after" "$OUT"
expect "+	1	zero
-	2	two
+	3	two-edited
+	4	three" "$(cat "$OUT")" "added lines carry their line in after, removed ones their line in before, across hunks"

pair_lines "$ROOT/before" "$ROOT/before" "$OUT"
expect "" "$(cat "$OUT")" "an unchanged file changes nothing"

printf 'one\n+++ not a header\n--- nor this\n' > "$ROOT/after"
pair_lines "$ROOT/before" "$ROOT/after" "$OUT"
expect "-	2	two
+	2	+++ not a header
+	3	--- nor this" "$(cat "$OUT")" "a body line starting with +++ or --- is content"

: > "$ROOT/empty"
pair_lines "$ROOT/empty" "$ROOT/before" "$OUT"
expect "+	1	one
+	2	two" "$(cat "$OUT")" "from nothing, every line"
pair_lines "$ROOT/before" "$ROOT/empty" "$OUT"
expect "-	1	one
-	2	two" "$(cat "$OUT")" "to nothing (the file removed), every line removed"

# --- session_lines: the lines the session added on net that the file holds -------
printf '+\t5\tadded\n+\t9\tgone\n' > "$ROOT/session-added"
printf 'old\nadded\nother\n' > "$ROOT/now"
session_lines "$ROOT/now" "$ROOT/session-added" "$OUT"
expect "2	added" "$(cat "$OUT")" "a line the session added is judged where it is now; one removed since is not"
printf '+\t1\tadded\n' > "$ROOT/session-added"
printf 'old\r\nadded\r\n' > "$ROOT/now"
session_lines "$ROOT/now" "$ROOT/session-added" "$OUT"
expect "2	added" "$(cat "$OUT")" "a CRLF line matches the added text git normalised to LF"
printf '+\t1\tadded\r\n' > "$ROOT/session-added"
printf 'added\n' > "$ROOT/now"
session_lines "$ROOT/now" "$ROOT/session-added" "$OUT"
expect "1	added" "$(cat "$OUT")" "an LF line matches added text that kept its CR"
: > "$ROOT/session-added"
session_lines "$ROOT/now" "$ROOT/session-added" "$OUT"
expect "" "$(cat "$OUT")" "no changes: nothing judged"

# judge <now> <before> <after> [<before> <after>...] -> what session_lines
# judges in <now> over the pairs, as content_gates feeds it. A pair's before
# need not be the previous pair's after: another writer changed the file in
# between.
judge() {
  local now=$1
  shift
  : > "$ROOT/changes"
  while [ "$#" -ge 2 ]; do
    pair_lines "$1" "$2" "$ROOT/pair"
    cat "$ROOT/pair" >> "$ROOT/changes"
    shift 2
  done
  session_lines "$now" "$ROOT/changes" "$OUT"
  cat "$OUT"
}
# v <name> <printf format> -> writes a version of a file, prints its path
v() {
  # shellcheck disable=SC2059 # the format is the fixture
  printf "$2" > "$ROOT/v.$1"
  printf '%s' "$ROOT/v.$1"
}

# The report (#343): L -> L' by one write, L' -> L by the next.
V0=$(v r0 'head\nL -home-token\ntail\n'); V1=$(v r1 'head\nL renamed\ntail\n')
expect "" "$(judge "$V0" "$V0" "$V1" "$V1" "$V0")" "a line one write changed and a later one restored is not judged (#343)"
# Partial revert: of two changed lines, one is restored.
V0=$(v p0 'a\nb\n'); V1=$(v p1 'a2\nb2\n'); V2=$(v p2 'a\nb2\n')
expect "2	b2" "$(judge "$V2" "$V0" "$V1" "$V1" "$V2")" "a partial revert judges only the line still changed"
# Change, then change again: only the last text.
V0=$(v c0 'x\nL\n'); V1=$(v c1 'x\nL1\n'); V2=$(v c2 'x\nL2\n')
expect "2	L2" "$(judge "$V2" "$V0" "$V1" "$V1" "$V2")" "L -> L' -> L'' judges L'' only"
# A second copy of a text the file already held: one copy judged, where the
# write put it.
V0=$(v d0 'L\nmid\n'); V1=$(v d1 'L\nmid\nL\n')
expect "3	L" "$(judge "$V1" "$V0" "$V1")" "a second copy of an existing text is judged once, at the added line"
# The added line moved since (another writer inserted above it): the last copy.
VN=$(v dn 'new top\nL\nmid\nL\n')
expect "4	L" "$(judge "$VN" "$V0" "$V1")" "a copy whose line moved since is judged at the last copy"
# Two copies added, one of them gone since: the one left.
V0=$(v f0 'x\n'); V1=$(v f1 'x\nL\nL\n'); VN=$(v fn 'x\nL\n')
expect "2	L" "$(judge "$VN" "$V0" "$V1")" "no more copies are judged than the file holds"
# A line moved within the file by one write.
V0=$(v m0 'L\na\nb\n'); V1=$(v m1 'a\nb\nL\n')
expect "" "$(judge "$V1" "$V0" "$V1")" "a line moved within the file is not judged"
# Moved across two writes: removed by one, put back elsewhere by the next.
V1=$(v m2 'a\nb\n'); V2=$(v m3 'a\nL\nb\n')
expect "" "$(judge "$V2" "$V0" "$V1" "$V1" "$V2")" "a line removed by one write and put back by another is not judged"
# Removed and restored (a file the session deleted and recreated).
V0=$(v g0 'L\nM\n')
expect "" "$(judge "$V0" "$V0" "$ROOT/empty" "$ROOT/empty" "$V0")" "a file removed and restored as it was judges nothing"
# Another writer between two of the session's writes: its line is in both the
# second pair's before and after, so it is never counted, revert or not.
V0=$(v o0 'L\n'); V1=$(v o1 'L2\n'); V1X=$(v o1x 'L2\nother\n'); V2=$(v o2 'L\nother\n')
expect "" "$(judge "$V2" "$V0" "$V1" "$V1X" "$V2")" "another writer's line between a change and its revert is not judged"
V2=$(v o3 'L3\nother\n')
expect "1	L3" "$(judge "$V2" "$V0" "$V1" "$V1X" "$V2")" "beside another writer's line, the session's own change is judged"
# Another writer removed a line the session added; the session added it again.
V0=$(v q0 'x\n'); V1=$(v q1 'x\nL\n'); V1X=$(v q1x 'x\n'); V2=$(v q2 'x\nL\n')
expect "2	L" "$(judge "$V2" "$V0" "$V1" "$V1X" "$V2")" "a line the session added twice, removed by another writer in between, is judged once"
# A CRLF side (a kept copy) against an LF blob nets to nothing.
V0=$(v k0 'L\n'); V1=$(v k1 'L\r\n')
expect "" "$(judge "$V1" "$V0" "$V1")" "a line whose only change is its line ending is not judged"

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
