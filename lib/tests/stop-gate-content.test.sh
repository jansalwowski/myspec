#!/usr/bin/env bash
# Function tests for lib/stop-gate/content.sh (R14, #263): which lines count
# as added (numbered from the hunk headers; the whole file when it is not in
# HEAD or HEAD is unborn), git's status per written path (renames included),
# and which roots the content gates own. The gate end to end:
# hooks/tests/verify-before-stop-content.test.sh.
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
OUT="$ROOT/added"

# --- added_lines on an unborn branch: the whole file -------------------------
printf 'one\ntwo\n' > "$REPO/docs/a.md"
added_lines "$REPO" docs/a.md "$OUT"
expect 1 "$CONTENT_WHOLE" "unborn HEAD: the whole file counts"
expect "1	one
2	two" "$(cat "$OUT")" "unborn HEAD: every line, numbered"

git -C "$REPO" add -A && git -C "$REPO" commit -q -m init

# --- added_lines against HEAD -----------------------------------------------
added_lines "$REPO" docs/a.md "$OUT"
expect 0 "$CONTENT_WHOLE" "a tracked file is diffed"
expect "" "$(cat "$OUT")" "an unchanged file adds nothing"

printf 'zero\none\ntwo-edited\nthree\n' > "$REPO/docs/a.md"
added_lines "$REPO" docs/a.md "$OUT"
expect "1	zero
3	two-edited
4	three" "$(cat "$OUT")" "added lines carry their line numbers across several hunks"

printf 'one\n+++ not a header\n' > "$REPO/docs/a.md"
added_lines "$REPO" docs/a.md "$OUT"
expect "2	+++ not a header" "$(cat "$OUT")" "a body line starting with +++ is content"

printf 'untracked\n' > "$REPO/docs/new.md"
added_lines "$REPO" docs/new.md "$OUT"
expect 1 "$CONTENT_WHOLE" "an untracked file is whole"
expect "1	untracked" "$(cat "$OUT")" "an untracked file's lines"

git -C "$REPO" add docs/new.md
added_lines "$REPO" docs/new.md "$OUT"
expect 1 "$CONTENT_WHOLE" "a staged new file is not in HEAD, so it is whole"

# --- content_changed / content_status ------------------------------------------
git -C "$REPO" checkout -q -- docs/a.md
git -C "$REPO" mv docs/new.md docs/moved.md
printf 'x\n' > "$REPO/docs/plain.md"
content_changed "$REPO"
expect "" "$(content_status docs/a.md)" "an unchanged file has no status"
expect "??" "$(content_status docs/plain.md)" "an untracked file is ??"
expect "A " "$(content_status docs/moved.md)" "a staged new file is A"
expect "" "$(content_status docs/nowhere.md)" "a path git never saw has no status"

git -C "$REPO" commit -q -m two
git -C "$REPO" mv docs/moved.md docs/renamed.md
content_changed "$REPO"
expect "R " "$(content_status docs/renamed.md)" "the new side of a rename carries R"
expect "R" "$(content_status docs/moved.md)" "the old side of a rename is listed, marked R"

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
