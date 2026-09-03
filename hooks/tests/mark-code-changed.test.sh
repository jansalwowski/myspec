#!/usr/bin/env bash
# Regression fixture for mark-code-changed.sh.
#
# Three things have to hold. The live log lands in .claude/state/sessions/ of
# the PRIMARY checkout — never in a linked worktree, never in the doc tree —
# and records every code path under `## Files touched`, exactly once, because
# that list is how a skill finds its own session. Bash writes create a log
# too, but only when a write verb and a code-file path are both visible at
# command position: a doc heredoc that merely mentions a code path, or a grep
# over one, must not. And a repository without .myspec.json gets the marker
# (code did change) but no log.
#
# Usage: mark-code-changed.test.sh [path-to-hook]

set -uo pipefail

HOOK="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../mark-code-changed.sh}"

if [ ! -x "$HOOK" ]; then
  echo "FATAL: hook not executable: $HOOK" >&2
  exit 1
fi

ROOT=$(cd "$(mktemp -d)" && pwd -P)
REPO="$ROOT/checkout"
mkdir -p "$REPO/src"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
git -C "$REPO" commit -q --allow-empty -m init
printf '{"aiDir":".ai","frameworkVersion":"2.0.0"}\n' > "$REPO/.myspec.json"
STATE="$REPO/.claude/state/sessions"
SID="mct-$$"
trap 'rm -rf "$ROOT"; rm -f /tmp/.myspec-code-changed-'"$SID"'-*' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

write() {  # write <sid> <cwd> <file-path>
  printf '{"session_id":%s,"tool_name":"Write","cwd":%s,"tool_input":{"file_path":%s}}' \
    "$(printf '%s' "$1" | jq -Rs .)" "$(printf '%s' "$2" | jq -Rs .)" "$(printf '%s' "$3" | jq -Rs .)" | bash "$HOOK" >/dev/null 2>&1
}

bashcmd() {  # bashcmd <sid> <cwd> <command>
  printf '{"session_id":%s,"tool_name":"Bash","cwd":%s,"tool_input":{"command":%s}}' \
    "$(printf '%s' "$1" | jq -Rs .)" "$(printf '%s' "$2" | jq -Rs .)" "$(printf '%s' "$3" | jq -Rs .)" | bash "$HOOK" >/dev/null 2>&1
}

expect_log() {  # expect_log <sid> <desc>
  if [ -f "$STATE/$1.md" ]; then ok; else fail "$2 (no log at .claude/state/sessions/$1.md)"; fi
}

expect_no_log() {
  if [ -f "$STATE/$1.md" ]; then fail "$2 (unexpected log at .claude/state/sessions/$1.md)"; else ok; fi
}

expect_in() {  # expect_in <sid> <fixed-string> <desc>
  if grep -qF -- "$2" "$STATE/$1.md" 2>/dev/null; then ok; else fail "$3 (log lacks: $2)"; fi
}

# --- Write tool: log in the state dir, files touched, once each ---------------
write "$SID-1" "$REPO" "$REPO/src/a.ts"
expect_log "$SID-1" "first code edit creates the log"
expect_in "$SID-1" "session_id: $SID-1" "log carries the session id"
expect_in "$SID-1" '- `src/a.ts`' "first path recorded under Files touched"
expect_in "$SID-1" 'Auto-created on first code edit' "context names the trigger"
if grep -q '^cwd:' "$STATE/$SID-1.md"; then fail "no cwd: placeholder is written any more"; else ok; fi
[ -f "/tmp/.myspec-code-changed-$SID-1" ] && ok || fail "marker file written for the Stop hook"
[ ! -e "$REPO/.ai/memory/sessions/active" ] && ok || fail "nothing is written under the doc tree"

write "$SID-1" "$REPO" "$REPO/src/b.ts"
write "$SID-1" "$REPO" "$REPO/src/a.ts"
expect_in "$SID-1" '- `src/b.ts`' "second path appended"
[ "$(grep -cF -- '- `src/a.ts`' "$STATE/$SID-1.md")" -eq 1 ] && ok || fail "a repeated path is recorded once"
[ "$(grep -c '^## Files touched' "$STATE/$SID-1.md")" -eq 1 ] && ok || fail "the Files touched heading is not duplicated"

# --- a doc edit is not a code edit --------------------------------------------
write "$SID-2" "$REPO" "$REPO/.ai/features/x/spec.md"
expect_no_log "$SID-2" "a doc edit creates no log"
[ ! -f "/tmp/.myspec-code-changed-$SID-2" ] && ok || fail "a doc edit leaves no marker"

# --- Bash writes ----------------------------------------------------------------
bashcmd "$SID-3" "$REPO" "sed -i '' 's/a/b/' src/c.ts"
expect_log "$SID-3" "sed -i on a code file creates the log"
expect_in "$SID-3" 'Auto-created on a Bash write' "context names the Bash trigger"
expect_in "$SID-3" '- `src/c.ts`' "the sed target is recorded"

bashcmd "$SID-4" "$REPO" 'echo "x" >> src/d.ts'
expect_log "$SID-4" "a redirect into a code file creates the log"
expect_in "$SID-4" '- `src/d.ts`' "the redirect target is recorded"

bashcmd "$SID-5" "$REPO" $'cat > notes.md <<\'EOF\'\nsee src/a.ts for details\nEOF'
expect_no_log "$SID-5" "a doc heredoc that mentions a code path creates no log"

bashcmd "$SID-6" "$REPO" 'grep -rn foo src/a.ts'
expect_no_log "$SID-6" "a read-only command over a code file creates no log"

bashcmd "$SID-7" "$REPO" 'yarn test src/e.ts 2>&1'
expect_no_log "$SID-7" "2>&1 is not a write"

bashcmd "$SID-8" "$REPO" 'git apply fix.patch'
expect_no_log "$SID-8" "a write verb with no visible code path creates no log"

# --- an edit inside a linked worktree logs in the PRIMARY checkout -----------
git -C "$REPO" worktree add -q "$REPO/.claude/worktrees/wt-a" -b wt-a
WT="$REPO/.claude/worktrees/wt-a"
mkdir -p "$WT/src"
write "$SID-9" "$WT" "$WT/src/w.ts"
expect_log "$SID-9" "worktree edit logs in the main checkout"
[ ! -e "$WT/.claude/state" ] && ok || fail "no state tree grows inside the worktree"
expect_in "$SID-9" 'worktree: "wt-a"' "worktree marker names the linked worktree"
expect_in "$SID-9" '- `.claude/worktrees/wt-a/src/w.ts`' "path is recorded relative to the main checkout"

# --- a 1.x log without the section gains it on the next edit ----------------
mkdir -p "$STATE"
printf -- '---\nsession_id: %s-10\nstatus: active\n---\n\n# old\n\n## Outcome\n' "$SID" > "$STATE/$SID-10.md"
write "$SID-10" "$REPO" "$REPO/src/f.ts"
expect_in "$SID-10" '## Files touched' "an older log gains the section"
expect_in "$SID-10" '- `src/f.ts`' "and the path"

# --- not a myspec project: marker, but no log -----------------------------------
OTHER="$ROOT/other"
mkdir -p "$OTHER/src"
git init -q -b main "$OTHER"
write "$SID-11" "$OTHER" "$OTHER/src/x.ts"
[ -f "/tmp/.myspec-code-changed-$SID-11" ] && ok || fail "marker still written outside a myspec project"
[ ! -e "$OTHER/.claude/state" ] && ok || fail "no log outside a myspec project"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
