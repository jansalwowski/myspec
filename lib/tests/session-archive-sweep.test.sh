#!/usr/bin/env bash
# Fixture for bootstrap's stale-session sweep (skills/bootstrap/SKILL.md,
# step 4), run as the skill prints it, with lib/main-checkout.sh and
# `session-event.sh dir` resolving where it reads and writes.
#
# Issue #392: the sweep listed .claude/state/sessions/ and archived into
# ${aiDir}/memory/sessions/archive/ relative to the cwd. From a linked
# worktree it missed the main checkout's live logs, and an archive written
# there died with `git worktree remove`. Now: from a linked worktree the
# main checkout's stale log is archived in the main checkout, unstaged; in a
# bare clone's worktree it is archived in that worktree and staged; outside
# git and any project nothing runs.
#
# Usage: session-archive-sweep.test.sh [path-to-plugin-root]

set -uo pipefail

PLUGIN="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SKILL="$PLUGIN/skills/bootstrap/SKILL.md"
[ -f "$SKILL" ] || { echo "FATAL: $SKILL not found" >&2; exit 1; }

ROOT=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

# The sweep block: from `NOW=$(date` to the end of its fence.
awk '/^NOW=\$\(date/ { on = 1 } on && /^```/ { exit } on { print }' "$SKILL" > "$ROOT/sweep.sh"
grep -q 'main-checkout.sh' "$ROOT/sweep.sh" || fail "the sweep block resolves the main checkout"

git_() { git -c user.email=t@t -c user.name=t "$@"; }
stale_log() {  # stale_log <dir> <id>
  mkdir -p "$1"
  printf -- '---\nstatus: active\n---\n' > "$1/$2.md"
  touch -t 202001010000 "$1/$2.md"
}
sweep() {  # sweep <cwd>
  (cd "$1" && CLAUDE_PLUGIN_ROOT="$PLUGIN" aiDir=ai bash "$ROOT/sweep.sh") >/dev/null 2>&1
}

# A linked worktree: the main checkout's log, archived in the main checkout.
REPO="$ROOT/repo"
git_ init -q -b main "$REPO"
printf '{}\n' > "$REPO/.myspec.json"
git_ -C "$REPO" add -A && git_ -C "$REPO" commit -q -m init
git_ -C "$REPO" worktree add -q -b wt "$ROOT/linked" >/dev/null 2>&1
stale_log "$REPO/.claude/state/sessions" abcdef1234
sweep "$ROOT/linked"
ARCH=$(find "$REPO/ai/memory/sessions/archive" -name '*-orphaned-abcdef12.md' 2>/dev/null)
[ -n "$ARCH" ] && ok || fail "linked worktree: the stale log is archived in the main checkout"
[ ! -e "$REPO/.claude/state/sessions/abcdef1234.md" ] && ok || fail "linked worktree: the live log is moved"
[ ! -e "$ROOT/linked/ai" ] && ok || fail "linked worktree: nothing is written into the worktree"
[ -n "$ARCH" ] && grep -q '^status: abandoned' "$ARCH" && ok || fail "linked worktree: status set to abandoned"
[ -z "$(git_ -C "$REPO" diff --cached --name-only)" ] && ok || fail "linked worktree: nothing staged in the main checkout"

# A bare clone's worktree: no main checkout, so this checkout, staged.
git_ init -q -b main "$ROOT/src" && git_ -C "$ROOT/src" commit -q --allow-empty -m init
git_ clone -q --bare "$ROOT/src" "$ROOT/b.git"
git_ -C "$ROOT/b.git" worktree add -q -b ba "$ROOT/ba" >/dev/null 2>&1
stale_log "$ROOT/b.git/myspec-state/sessions" 1234567890
sweep "$ROOT/ba"
case "$(git_ -C "$ROOT/ba" diff --cached --name-only)" in
  ai/memory/sessions/archive/*-orphaned-12345678.md) ok ;;
  *) fail "bare worktree: the stale log is archived and staged in this checkout" ;;
esac

# Outside git and any project: nothing is resolved, nothing runs.
mkdir -p "$ROOT/nogit/.claude/state/sessions"
stale_log "$ROOT/nogit/.claude/state/sessions" ffffffff00
sweep "$ROOT/nogit"
[ -e "$ROOT/nogit/.claude/state/sessions/ffffffff00.md" ] && [ ! -e "$ROOT/nogit/ai" ] && ok \
  || fail "no git, no .myspec.json: the sweep is skipped"

echo "session-archive-sweep: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
