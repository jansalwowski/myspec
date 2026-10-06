#!/usr/bin/env bash
# Timing regression for mark-code-changed.sh (#277). The hook runs at
# PreToolUse and PostToolUse (and PostToolUseFailure) of every Bash call, and
# spent processes per statement and per target: a 200-statement command that
# appends to ten docs took 20-30 s per hook call on macOS. A call now costs
# well under a second; the bounds below are ten times that or more, so a
# slow CI runner does not flake, while the old cost overshoots them several
# times over. Each case also checks what was recorded, so a fast hook that
# records nothing cannot pass.
#
# Usage: mark-code-changed-perf.test.sh [path-to-hook]

set -uo pipefail

HOOK="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../mark-code-changed.sh}"
# The hooks find their lib through CLAUDE_PLUGIN_ROOT, as the harness exports it.
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$HOOK")/.." && pwd)}"

ROOT=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

# fixture <name> -> a fresh myspec repository with a docs/ directory.
fixture() {
  local repo="$ROOT/$1"
  mkdir -p "$repo/docs"
  git init -q "$repo"
  git -C "$repo" config user.email t@t
  git -C "$repo" config user.name t
  printf '{"aiDir":".ai","frameworkVersion":"3.0.0"}\n' > "$repo/.myspec.json"
  printf '.claude/state/\n' > "$repo/.gitignore"
  git -C "$repo" add -A
  git -C "$repo" commit -qm init
  printf '%s\n' "$repo"
}

# timed <event> <repo> <command> [tool_use_id] -> runs the hook once;
# ELAPSED is the whole seconds it took. With a tool_use_id the status diff
# runs too (#276).
timed() {
  local start=$SECONDS
  jq -nc --arg e "$1" --arg c "$2" --arg cmd "$3" --arg id "${4:-}" \
    '{hook_event_name: $e, session_id: "perf", tool_name: "Bash", cwd: $c, tool_input: {command: $cmd}}
     + (if $id != "" then {tool_use_id: $id} else {} end)' \
    | bash "$HOOK" >/dev/null 2>&1
  ELAPSED=$((SECONDS - start))
}

# events <repo> <t> -> how many events of that type the session recorded.
events() {
  jq -r --arg t "$2" 'select(.t == $t) | .t' "$1/.claude/state/sessions/perf.jsonl" 2>/dev/null | wc -l | tr -d ' '
}

within() {  # within <bound seconds> <desc>
  if [ "$ELAPSED" -le "$1" ]; then ok; else fail "$2: ${ELAPSED}s, bound ${1}s"; fi
}

# 400 statements that write nothing: the gate decides in one pass.
CMD=""
for i in $(seq 1 400); do CMD="${CMD}echo line $i; "; done
REPO=$(fixture echo)
timed PreToolUse "$REPO" "$CMD"
within 2 "400 statements with no write, PreToolUse"
timed PostToolUse "$REPO" "$CMD"
within 2 "400 statements with no write, PostToolUse"

# 200 appends to ten docs: each file is recorded once, with its snapshots.
CMD=""
for i in $(seq 1 200); do CMD="${CMD}printf 'x\\n' >> docs/f$((i % 10)).md; "; done
REPO=$(fixture ten)
timed PreToolUse "$REPO" "$CMD"
within 5 "200 appends to ten docs, PreToolUse"
[ "$(events "$REPO" pre)" = 10 ] && ok || fail "200 appends to ten docs: one pre event per file"
for i in $(seq 0 9); do printf 'x\n' >> "$REPO/docs/f$i.md"; done
timed PostToolUse "$REPO" "$CMD"
within 5 "200 appends to ten docs, PostToolUse"
[ "$(events "$REPO" write)" = 10 ] && ok || fail "200 appends to ten docs: one write event per file"
BLOBBED=$(jq -r 'select(.t == "write" and (.blob | test("^[0-9a-f]{40,}$"))) | .rel' \
  "$REPO/.claude/state/sessions/perf.jsonl" | sort -u | wc -l | tr -d ' ')
[ "$BLOBBED" = 10 ] && ok || fail "200 appends to ten docs: each write carries its after-blob ($BLOBBED)"

# 200 appends to 200 docs: the per-file work is batched per checkout.
CMD=""
for i in $(seq 1 200); do CMD="${CMD}printf 'x\\n' >> docs/g$i.md; "; done
REPO=$(fixture many)
timed PreToolUse "$REPO" "$CMD"
within 5 "200 appends to 200 docs, PreToolUse"
for i in $(seq 1 200); do printf 'x\n' >> "$REPO/docs/g$i.md"; done
timed PostToolUse "$REPO" "$CMD"
within 5 "200 appends to 200 docs, PostToolUse"
[ "$(events "$REPO" write)" = 200 ] && ok || fail "200 appends to 200 docs: one write event per file"

# The same 200 appends to 200 docs with the status diff on: a capture before,
# a diff after, and the writes still recorded once each.
REPO=$(fixture diffed)
timed PreToolUse "$REPO" "$CMD" toolu_perf
within 5 "200 appends to 200 docs with the status diff, PreToolUse"
for i in $(seq 1 200); do printf 'x\n' >> "$REPO/docs/g$i.md"; done
timed PostToolUse "$REPO" "$CMD" toolu_perf
within 5 "200 appends to 200 docs with the status diff, PostToolUse"
[ "$(events "$REPO" write)" = 200 ] && ok || fail "200 appends to 200 docs with the status diff: one write event per file"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
