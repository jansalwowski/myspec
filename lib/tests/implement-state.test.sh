#!/usr/bin/env bash
# Tests for implement-state.sh: feature-implement's run-state directory.
#
# The properties under test: init creates the directory, prints its absolute
# path and makes git ignore it (once, and not at all when a .gitignore already
# does); stamp appends one "<stage> <epoch>" line per call; probe-run hands out
# run-1, run-2, ... without reusing one; every checkout of a repository gets
# the main checkout's state (#441), and a state directory left in a linked
# worktree by an older version moves there, from whichever checkout runs
# first; a bad argument or a directory outside git creates nothing.
#
# Usage: implement-state.test.sh [path-to-script]

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${1:-$HERE/../implement-state.sh}"
[ -x "$SCRIPT" ] || { echo "FATAL: script not executable: $SCRIPT" >&2; exit 1; }

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
nok() { fail=$((fail + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     /'; }
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else nok "$1" "expected: [$3]"$'\n'"actual:   [$2]"; fi; }

REPO="$ROOT/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
REPO=$(cd "$REPO" && pwd -P)
excluded() { grep -cxF '.claude/state/' "$REPO/.git/info/exclude" 2>/dev/null || true; }

echo "# init"
out=$(cd "$REPO/" && "$SCRIPT" init invoice-due-dates)
expect_eq "prints the absolute state path" "$out" "$REPO/.claude/state/implement/invoice-due-dates"
[ -d "$out" ] && ok "creates the directory" || nok "creates the directory"
expect_eq "adds .claude/state/ to info/exclude" "$(excluded)" 1
git -C "$REPO" check-ignore -q "$out" && ok "git now ignores the state directory" || nok "git now ignores the state directory"
(cd "$REPO" && "$SCRIPT" init invoice-due-dates >/dev/null)
expect_eq "a second init adds no second exclude line" "$(excluded)" 1
mkdir -p "$REPO/app"
expect_eq "from a subdirectory: the checkout's toplevel" "$(cd "$REPO/app" && "$SCRIPT" init invoice-due-dates)" "$REPO/.claude/state/implement/invoice-due-dates"

echo "# init where a .gitignore already ignores .claude/state/"
G="$ROOT/ignored"
mkdir -p "$G" && git -C "$G" init -q -b main && printf '.claude/state/\n' > "$G/.gitignore"
(cd "$G" && "$SCRIPT" init f >/dev/null)
expect_eq "no info/exclude line when .gitignore already covers it" "$(grep -cxF '.claude/state/' "$G/.git/info/exclude" 2>/dev/null || true)" 0

echo "# stamp"
(cd "$REPO" && "$SCRIPT" stamp invoice-due-dates 1 implement && "$SCRIPT" stamp invoice-due-dates 1 barrier)
T="$REPO/.claude/state/implement/invoice-due-dates/phase-1.times"
expect_eq "one line per stamp, in order" "$(cut -d' ' -f1 "$T" | tr '\n' ' ')" "implement barrier "
if grep -qE '^implement [0-9]{9,}$' "$T"; then ok "each line carries epoch seconds"; else nok "each line carries epoch seconds" "$(cat "$T")"; fi
(cd "$REPO" && "$SCRIPT" stamp invoice-due-dates 3a review)
[ -f "$REPO/.claude/state/implement/invoice-due-dates/phase-3a.times" ] && ok "a dual-stream phase id (3a) is a valid phase" || nok "a dual-stream phase id (3a) is a valid phase"

echo "# probe-run"
r1=$(cd "$REPO" && "$SCRIPT" probe-run invoice-due-dates 1)
r2=$(cd "$REPO" && "$SCRIPT" probe-run invoice-due-dates 1)
P="$REPO/.claude/state/implement/invoice-due-dates/probes/milestone-1"
expect_eq "first run is run-1, the next run-2" "$r1 $r2" "$P/run-1 $P/run-2"
[ -d "$r2" ] && ok "creates the run directory" || nok "creates the run directory"
rm -rf "$P/run-1"
expect_eq "a gap is reused, as the skill's loop did" "$(cd "$REPO" && "$SCRIPT" probe-run invoice-due-dates 1)" "$P/run-1"

echo "# a linked worktree shares the main checkout's state (#441)"
git -C "$REPO" worktree add -q "$ROOT/wt" -b wt
WT=$(cd "$ROOT/wt" && pwd -P)
MS="$REPO/.claude/state/implement/f"
expect_eq "init from a worktree prints the main checkout's path" "$(cd "$WT" && "$SCRIPT" init f)" "$MS"
[ ! -e "$WT/.claude/state" ] && ok "nothing is created in the worktree" || nok "nothing is created in the worktree"
(cd "$WT" && "$SCRIPT" stamp f 1 implement) && (cd "$REPO" && "$SCRIPT" stamp f 1 barrier)
expect_eq "stamps from both checkouts land in one file" "$(cut -d' ' -f1 "$MS/phase-1.times" | tr '\n' ' ')" "implement barrier "
git -C "$REPO" worktree remove "$WT"
git -C "$REPO" worktree add -q "$ROOT/wt" wt
expect_eq "a worktree created again finds the stamps" "$(cd "$WT" && "$SCRIPT" init f >/dev/null && cut -d' ' -f1 "$MS/phase-1.times" | tr '\n' ' ')" "implement barrier "

echo "# state from before #441 in any checkout moves to the main checkout"
mkdir -p "$WT/.claude/state/implement/g" && printf 'implement 1\n' > "$WT/.claude/state/implement/g/phase-1.times"
err=$(cd "$WT" && "$SCRIPT" init g 2>&1 >/dev/null)
expect_eq "the stamps are moved" "$(cat "$REPO/.claude/state/implement/g/phase-1.times" 2>/dev/null)" "implement 1"
[ ! -e "$WT/.claude/state/implement/g" ] && ok "the old directory is gone" || nok "the old directory is gone"
case "$err" in *"moved $WT/.claude/state/implement/g"*) ok "the move is reported on stderr" ;; *) nok "the move is reported on stderr" "$err" ;; esac
mkdir -p "$WT/.claude/state/implement/g" && printf 'implement 2\n' > "$WT/.claude/state/implement/g/phase-1.times"
err=$(cd "$WT" && "$SCRIPT" init g 2>&1 >/dev/null)
expect_eq "when both exist, the main checkout's stays" "$(cat "$REPO/.claude/state/implement/g/phase-1.times")" "implement 1"
[ -f "$WT/.claude/state/implement/g/phase-1.times" ] && ok "and the old one is left alone" || nok "and the old one is left alone"
case "$err" in *"also holds state"*) ok "with a warning naming it" ;; *) nok "with a warning naming it" "$err" ;; esac
mkdir -p "$WT/.claude/state/implement/h" && printf 'implement 1\n' > "$WT/.claude/state/implement/h/phase-1.times"
(cd "$REPO" && "$SCRIPT" init h >/dev/null 2>&1)
expect_eq "init from the main checkout finds a worktree's old state" "$(cat "$REPO/.claude/state/implement/h/phase-1.times" 2>/dev/null)" "implement 1"
mkdir -p "$REPO/.claude/state/implement/k" "$WT/.claude/state/implement/k" && printf 'implement 1\n' > "$WT/.claude/state/implement/k/phase-1.times"
(cd "$WT" && "$SCRIPT" init k >/dev/null 2>&1)
expect_eq "an empty state directory does not block the move" "$(cat "$REPO/.claude/state/implement/k/phase-1.times" 2>/dev/null)" "implement 1"

echo "# a bare clone with worktrees keeps it in the common dir"
git clone -q --bare "$REPO" "$ROOT/bare.git"
git -C "$ROOT/bare.git" worktree add -q "$ROOT/bwt" -b bw 2>/dev/null
BARE=$(cd "$ROOT/bare.git" && pwd -P)
expect_eq "state under myspec-state/implement" "$(cd "$ROOT/bwt" && "$SCRIPT" init f)" "$BARE/myspec-state/implement/f"

echo "# bad input creates nothing"
for args in "init ../x" "init .hidden" "init a/b" "stamp f 1" "stamp f 1/2 x" "probe-run f" "frobnicate f" "init"; do
  # shellcheck disable=SC2086 # the args are split on purpose
  if (cd "$REPO" && "$SCRIPT" $args >/dev/null 2>&1); then nok "rejects: $args"; else ok "rejects: $args"; fi
done
[ ! -e "$REPO/.claude/state/x" ] && [ ! -e "$REPO/.claude/state/implement/a" ] && ok "no path escaped the state directory" || nok "no path escaped the state directory"
mkdir -p "$ROOT/nogit"
if (cd "$ROOT/nogit" && "$SCRIPT" init f >/dev/null 2>&1); then nok "outside git: exit 1"; else ok "outside git: exit 1"; fi
[ ! -e "$ROOT/nogit/.claude" ] && ok "outside git: nothing created" || nok "outside git: nothing created"

echo "implement-state: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
