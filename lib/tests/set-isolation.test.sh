#!/usr/bin/env bash
# Regression fixture for set-isolation.sh.
#
# Issue #146: the model never sees its own session id, so a session that took
# the id from another session's live log silently replaced that session's
# answer. A live decision may now only gain a worktree path; flipping the mode
# or repointing the path needs an explicit --reset. The decision is an
# `isolation` event in the session-state file (lib/session-event.sh) of the
# main checkout; the session's last one decides.
#
# Runs against a synthetic checkout in a temp dir; never touches a real repo.
# Usage: set-isolation.test.sh [path-to-set-isolation.sh]

set -uo pipefail

LIB="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../set-isolation.sh}"

if [ ! -x "$LIB" ]; then
  echo "FATAL: script not executable: $LIB" >&2
  exit 1
fi

ROOT=$(cd "$(mktemp -d)" && pwd -P)
REPO="$ROOT/checkout"
git init -q -b main "$REPO"
trap 'rm -rf "$ROOT"' EXIT
STATE="$REPO/.claude/state/sessions"

PASS=0
FAIL=0

run() {  # run <args...> → exit status; output discarded
  (cd "$REPO" && "$LIB" "$@") >/dev/null 2>&1
}

expect() {  # expect <want-rc> <desc> <args...>
  local want="$1" desc="$2" rc
  shift 2
  run "$@"
  rc=$?
  if [ "$rc" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL  want rc=%s got rc=%s  %s (set-isolation.sh %s)\n' "$want" "$rc" "$desc" "$*" >&2
  fi
}

field() {  # field <session-id> <jq field> -> from the session's last isolation event
  jq -rs "map(select(.t == \"isolation\")) | last | .$2 // empty" "$STATE/$1.jsonl" 2>/dev/null
}

assert_eq() {  # assert_eq <want> <got> <desc>
  if [ "$1" = "$2" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL  %s: want %s, got %s\n' "$3" "$1" "$2" >&2
  fi
}

expect 0 "first decision is recorded"            sess-a worktree
assert_eq worktree "$(field sess-a mode)" "first decision mode"
expect 0 "same answer, worktree path added later" sess-a worktree --worktree-path /wt/a
assert_eq /wt/a "$(field sess-a path)" "path added by a re-run"
expect 0 "same answer re-run without the path"   sess-a worktree
assert_eq /wt/a "$(field sess-a path)" "re-run without a path keeps the recorded one"

expect 1 "another session flips the mode"        sess-a develop
assert_eq worktree "$(field sess-a mode)" "a refused flip leaves the decision alone"
expect 1 "another session repoints the worktree" sess-a worktree --worktree-path /wt/b
assert_eq /wt/a "$(field sess-a path)" "a refused repoint leaves the path alone"

OUT=$( (cd "$REPO" && "$LIB" sess-a develop) 2>&1 >/dev/null)
case "$OUT" in
  *"--reset sess-a"*) PASS=$((PASS + 1)) ;;
  *) FAIL=$((FAIL + 1)); printf 'FAIL  refusal does not name the reset: %s\n' "$OUT" >&2 ;;
esac

expect 0 "reset"                                 --reset sess-a
expect 0 "after a reset the answer can change"   sess-a develop
assert_eq develop "$(field sess-a mode)" "mode after reset"

# An expired decision never blocks a new answer.
printf '{"t":"isolation","mode":"worktree","path":"","at":%d}\n' "$(( $(date +%s) - 30000 ))" > "$STATE/sess-old.jsonl"
expect 0 "expired decision is replaced"          sess-old develop
assert_eq develop "$(field sess-old mode)" "mode after replacing an expired decision"

# Other sessions' decisions are untouched by a new id.
expect 0 "a new id records its own decision"     sess-b worktree
assert_eq develop "$(field sess-a mode)" "a new id leaves another decision alone"

# A worktree cwd files the decision in the main checkout.
git -C "$REPO" commit -q --allow-empty -m init
git -C "$REPO" worktree add -q -b wt "$ROOT/wt"
(cd "$ROOT/wt" && "$LIB" sess-c develop) >/dev/null 2>&1
assert_eq develop "$(field sess-c mode)" "a decision made in a linked worktree lands in the main checkout"
[ ! -e "$ROOT/wt/.claude/state" ] && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); echo "FAIL  no state tree in the worktree" >&2; }

# --show lists the live decisions, not a reset or an expired one.
expect 0 "reset sess-b"                          --reset sess-b
SHOW=$( (cd "$REPO" && "$LIB" --show) 2>&1)
case "$SHOW" in
  *"sess-a"*"mode=develop"*) PASS=$((PASS + 1)) ;;
  *) FAIL=$((FAIL + 1)); printf 'FAIL  --show lists a live decision: %s\n' "$SHOW" >&2 ;;
esac
case "$SHOW" in
  *sess-b*) FAIL=$((FAIL + 1)); printf 'FAIL  --show leaves out a reset decision: %s\n' "$SHOW" >&2 ;;
  *) PASS=$((PASS + 1)) ;;
esac
expect 1 "a session id that is not a file name is refused" ../x develop

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
