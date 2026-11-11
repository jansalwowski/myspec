#!/usr/bin/env bash
# Concurrency regression for mark-code-changed.sh. Claude Code runs the hooks
# of parallel tool calls at once, so several PostToolUse hooks of one session
# find no live log at the same moment. Each used to create it with `cat >`,
# which truncated the entries the others had appended since: 40 concurrent
# edits left 33 to 39 paths in the log in 6 rounds of 10, while the
# session-state file kept all 40. The log is now linked into place whole, so
# every round must hold every path once, under one header.
#
# Usage: mark-code-changed-concurrency.test.sh [path-to-hook]

set -uo pipefail

HOOK="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../mark-code-changed.sh}"
# The hooks find their lib through CLAUDE_PLUGIN_ROOT, as the harness exports it.
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$HOOK")/.." && pwd)}"

ROOT=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT
REPO="$ROOT/checkout"
mkdir -p "$REPO/src"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
git -C "$REPO" commit -q --allow-empty -m init
printf '{"aiDir":".ai","frameworkVersion":"3.0.0"}\n' > "$REPO/.myspec.json"
STATE="$REPO/.claude/state/sessions"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

N=40
ROUNDS=5

# burst <sid>: N Edit hooks of one session at once, one file each.
burst() {
  local i
  for ((i = 1; i <= N; i++)); do
    jq -nc --arg s "$1" --arg c "$REPO" --arg f "$REPO/src/f$i.ts" \
      '{hook_event_name: "PostToolUse", session_id: $s, tool_name: "Edit", cwd: $c, tool_input: {file_path: $f, old_string: "a", new_string: "b"}}' \
      | bash "$HOOK" >/dev/null 2>&1 &
  done
  wait
}

# entries <sid> -> how many distinct src/f<i>.ts entry lines the log holds.
entries() {
  # shellcheck disable=SC2016 # literal backticks: a markdown code span
  grep -xE -- '- `src/f[0-9]+\.ts`' "$STATE/$1.md" 2>/dev/null | sort -u | wc -l | tr -d ' '
}

# count <sid> <ERE> -> how many lines of the log match.
count() {
  grep -cE -- "$2" "$STATE/$1.md" 2>/dev/null || true
}

# --- N hooks create the log at once: every path, one header ---------------------
for ((r = 1; r <= ROUNDS; r++)); do
  sid="race-$r"
  burst "$sid"
  got=$(entries "$sid")
  [ "$got" = "$N" ] && ok || fail "round $r: the log holds all $N paths of $N concurrent edits (got: $got)"
  # shellcheck disable=SC2016 # literal backticks: a markdown code span
  [ "$(count "$sid" '^- `src/f[0-9]+\.ts`$')" = "$N" ] && ok || fail "round $r: each path is logged once"
  [ "$(count "$sid" '^session_id: ')" = 1 ] && [ "$(count "$sid" '^## Files touched$')" = 1 ] && ok \
    || fail "round $r: the log has one front matter and one Files touched section"
  [ "$(head -1 "$STATE/$sid.md" 2>/dev/null)" = "---" ] && ok || fail "round $r: the log starts with its front matter"
  [ "$(jq -r 'select(.t == "write") | .rel' "$STATE/$sid.jsonl" 2>/dev/null | sort -u | wc -l | tr -d ' ')" = "$N" ] && ok \
    || fail "round $r: the session-state file holds all $N writes"
done

# --- a log that exists is never replaced ----------------------------------------
printf -- '---\nsession_id: race-kept\nstatus: active\n---\n\n# kept\n\n## Files touched\n' > "$STATE/race-kept.md"
burst race-kept
[ "$(entries race-kept)" = "$N" ] && ok || fail "an existing log gains all $N paths (got: $(entries race-kept))"
[ "$(count race-kept '^# kept$')" = 1 ] && [ "$(count race-kept '^auto_created: ')" = 0 ] && ok \
  || fail "an existing log keeps its own header"

# --- no temporary file stays behind ---------------------------------------------
LEFT=$(find "$STATE" -maxdepth 1 -type f ! -name '*.md' ! -name '*.jsonl' | wc -l | tr -d ' ')
[ "$LEFT" = 0 ] && ok || fail "the state directory holds only logs and state files (extra: $(find "$STATE" -maxdepth 1 -type f ! -name '*.md' ! -name '*.jsonl' | tr '\n' ' '))"
[ "$(find "$STATE" -maxdepth 1 -name '.*.md*' | wc -l | tr -d ' ')" = 0 ] && ok || fail "no temporary log file stays behind"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
