#!/usr/bin/env bash
# Regression fixture for housekeep.sh.
#
# housekeep removes without asking, so each step must remove exactly what its
# rule proves safe and nothing else: a merged branch but not an unpushed one,
# old session state but not a running session's, an idle brainstorm session
# but not a recent or served one. --dry-run removes nothing and writes no
# stamp. No network and no gh: branch-cleanup.sh's own fixture covers its
# proofs; this one covers the wiring.
#
# Usage: housekeep.test.sh [path-to-script]

set -uo pipefail

SCRIPT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../housekeep.sh}"
[ -x "$SCRIPT" ] || { echo "FATAL: script not executable: $SCRIPT" >&2; exit 1; }

ROOT=$(cd "$(mktemp -d)" && pwd -P)
REPO="$ROOT/repo"
SLEEPER=""
trap '[ -n "$SLEEPER" ] && kill "$SLEEPER" 2>/dev/null; rm -rf "$ROOT"' EXIT
# gh must not answer for these synthetic branches.
export PATH="$ROOT/bin:$PATH"
mkdir -p "$ROOT/bin" "$REPO"
printf '#!/bin/sh\nexit 1\n' > "$ROOT/bin/gh"
chmod +x "$ROOT/bin/gh"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

# old <path> <days>: back-date a file or directory tree
old() { find "$1" -exec touch -t "$(date -r $(( $(date +%s) - $2 * 86400 )) +%Y%m%d%H%M 2>/dev/null || date -d "@$(( $(date +%s) - $2 * 86400 ))" +%Y%m%d%H%M)" {} +; }

cd "$REPO" || exit 1
git init -q -b main .
git config user.email t@t
git config user.name t
printf '.claude/state/\n.myspec/\n' > .gitignore
echo '{ "aiDir": ".ai" }' > .myspec.json
echo base > base.txt
git add -A && git commit -qm init
git clone -q --bare . "$ROOT/origin.git"
git remote add origin "$ROOT/origin.git"
git push -q -u origin main
git remote set-head origin main

# merged: pushed, then fast-forwarded into main
git checkout -q -b merged; echo a > a.txt; git add -A; git commit -qm a; git push -q -u origin merged
git checkout -q main; git merge -q --ff-only merged; git push -q origin main
# local-only: never pushed
git checkout -q -b local-only; echo b > b.txt; git add -A; git commit -qm b
git checkout -q main

S="$REPO/.claude/state/sessions"
mkdir -p "$S/old.blobs" "$S/old.bash"
echo '{}' > "$S/old.jsonl"; echo x > "$S/old.blobs/x"
echo '{}' > "$S/new.jsonl"
echo log > "$S/stale.md"
old "$S/old.jsonl" 2; old "$S/stale.md" 2

B="$REPO/.myspec/brainstorm"
mkdir -p "$B/idle/state" "$B/recent/state" "$B/served/state"
echo x > "$B/idle/content.html"; echo x > "$B/recent/content.html"; echo x > "$B/served/content.html"
sleep 300 & SLEEPER=$!
disown "$SLEEPER" 2>/dev/null
echo "$SLEEPER" > "$B/served/state/server.pid"
echo 999999 > "$B/idle/state/server.pid"
old "$B/idle" 10; old "$B/served" 10
echo '*' > "$B/.gitignore"

# --- dry run ------------------------------------------------------------------
OUT=$("$SCRIPT" --dry-run --no-fetch 2>&1); STATUS=$?
[ "$STATUS" -eq 0 ] && ok || fail "dry run exits 0 (got $STATUS): $OUT"
printf '%s' "$OUT" | grep -qE '^branches: would remove 1 merged \(merged\)' && ok || fail "dry run names the merged branch (got: $OUT)"
printf '%s' "$OUT" | grep -qF 'sessions: would remove 1 state file' && ok || fail "dry run counts the old state file"
printf '%s' "$OUT" | grep -qF '1 live log(s) older than 6h' && ok || fail "dry run counts the stale live log"
printf '%s' "$OUT" | grep -qF 'brainstorm: would remove 1 session(s)' && ok || fail "dry run counts the idle brainstorm session"
git rev-parse --verify -q merged >/dev/null && [ -f "$S/old.jsonl" ] && [ -d "$B/idle" ] && ok || fail "dry run removes nothing"
[ ! -e "$REPO/.claude/state/housekeep-last-run" ] && ok || fail "dry run writes no stamp"

# --- real run -----------------------------------------------------------------
OUT=$("$SCRIPT" --no-fetch 2>&1); STATUS=$?
[ "$STATUS" -eq 0 ] && ok || fail "run exits 0 (got $STATUS): $OUT"
! git rev-parse --verify -q merged >/dev/null && ok || fail "the merged branch is deleted"
git rev-parse --verify -q local-only >/dev/null && ok || fail "the never-pushed branch is kept"
[ ! -e "$S/old.jsonl" ] && [ ! -e "$S/old.blobs" ] && [ ! -e "$S/old.bash" ] && ok || fail "the old state file and its directories are removed"
[ -f "$S/new.jsonl" ] && ok || fail "the fresh state file is kept"
[ -f "$S/stale.md" ] && ok || fail "live logs are only counted, never removed"
[ ! -e "$B/idle" ] && ok || fail "the idle brainstorm session is removed"
[ -d "$B/recent" ] && ok || fail "the recent brainstorm session is kept"
[ -d "$B/served" ] && ok || fail "the served brainstorm session is kept"
[ -f "$B/.gitignore" ] && ok || fail "the brainstorm .gitignore is kept"
[ -s "$REPO/.claude/state/housekeep-last-run" ] && ok || fail "the run writes the stamp"
printf '%s' "$OUT" | grep -qE '^memory: ' && ok || fail "the memory step reports (got: $OUT)"

# --- from a linked worktree ---------------------------------------------------
git worktree add -q "$ROOT/wt" -b wt-branch
git -C "$ROOT/wt" push -q -u origin wt-branch
# Two guards keep it: housekeep's filter on the branch where it runs, and the
# --unattended process veto (housekeep's own cwd is inside it), which this
# test cannot switch off portably. The report names the held worktree.
touch -t "$(date -r $(( $(date +%s) - 7200 )) +%Y%m%d%H%M 2>/dev/null || date -d "@$(( $(date +%s) - 7200 ))" +%Y%m%d%H%M)" "$ROOT/wt"
OUT=$(cd "$ROOT/wt" && "$SCRIPT" --no-fetch 2>&1)
git rev-parse --verify -q wt-branch >/dev/null && [ -d "$ROOT/wt" ] && ok || fail "the branch checked out where housekeep runs is kept (got: $OUT)"
printf '%s' "$OUT" | grep -qF 'may be in use, run /myspec:worktree-clean' && ok || fail "the report points held worktrees at worktree-clean (got: $OUT)"

OUT=$("$SCRIPT" --stale-days x 2>&1); STATUS=$?
[ "$STATUS" -eq 2 ] && ok || fail "a bad --stale-days exits 2 (got $STATUS)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
