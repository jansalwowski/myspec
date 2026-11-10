#!/usr/bin/env bash
# Fixture for visualize-options' Submit wait (skills/visualize-options/SKILL.md,
# step 3), run as the skill prints it.
#
# Issue #411: on a normal Submit, server-stopped does not exist, so the
# trailing `cat` failed and the command exited 1 after printing the answer.
# Run in the background, the task then reported "failed". Now every way the
# wait ends (Submit, server stopped, session dir gone) exits 0.
#
# Usage: visualize-options-wait.test.sh [path-to-plugin-root]

set -uo pipefail

PLUGIN="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SKILL="$PLUGIN/skills/visualize-options/SKILL.md"
[ -f "$SKILL" ] || { echo "FATAL: $SKILL not found" >&2; exit 1; }

ROOT=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

# The wait line, with its placeholders filled for screen s1 and $ROOT/state.
WAIT=$(grep -m1 '^until grep' "$SKILL")
[ -n "$WAIT" ] || { echo "FATAL: no wait loop in $SKILL" >&2; exit 1; }
WAIT=${WAIT//\{id\}/s1}
WAIT=${WAIT//<state_dir>/$ROOT/state}

wait_() {  # wait_ -> sets OUT and RC; the state is prepared before the call
  OUT=$(bash -c "$WAIT" 2>&1)
  RC=$?
}

# Submit: answer.json names this screen, no server-stopped.
rm -rf "$ROOT/state"; mkdir -p "$ROOT/state"
echo '{"screen": "s1.html", "answers": {}}' > "$ROOT/state/answer.json"
wait_
[ "$RC" = 0 ] && ok || fail "Submit: the wait exits 0 (got $RC)"
case "$OUT" in *'"screen": "s1.html"'*) ok ;; *) fail "Submit: the wait prints answer.json" ;; esac

# Server stopped while an earlier screen's answer is still on disk.
rm -rf "$ROOT/state"; mkdir -p "$ROOT/state"
echo '{"screen": "s0.html", "answers": {}}' > "$ROOT/state/answer.json"
echo 'stopped: idle' > "$ROOT/state/server-stopped"
wait_
[ "$RC" = 0 ] && ok || fail "server stopped: the wait exits 0 (got $RC)"
case "$OUT" in *'stopped: idle'*) ok ;; *) fail "server stopped: the wait prints server-stopped" ;; esac

# Session dir gone (a temp session deleted, a killed server).
rm -rf "$ROOT/state"
wait_
[ "$RC" = 0 ] && ok || fail "dir gone: the wait exits 0 (got $RC)"

echo "visualize-options-wait: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
