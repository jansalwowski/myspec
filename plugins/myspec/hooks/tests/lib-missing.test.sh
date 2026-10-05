#!/usr/bin/env bash
# Regression fixture: a hook that cannot find its lib says so (#262 review).
#
# Since 3.0 every hook finds hook-core.sh under CLAUDE_PLUGIN_ROOT, which the
# harness exports to a hook the plugin's hooks.json declares. A hook started
# without it (a stale copy wired in .claude/settings.json, a harness that
# substitutes the variable in the command but does not export it) must not
# approve in silence, as the first 3.0 draft did: a PreToolUse hook denies
# with a reason naming the variable and /myspec:update, a PostToolUse or
# SessionEnd hook, which cannot deny, prints the same line to stderr and
# exits 0, and the Stop hook blocks once (verify-before-stop-regression
# covers that one). With the variable pointing at a plugin whose lib/ exists,
# every hook runs as before.
#
# Usage: lib-missing.test.sh

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN=$(cd "$HERE/../.." && pwd)

ROOT=$(cd "$(mktemp -d)" && pwd -P)
REPO="$ROOT/repo"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$REPO/src"
git init -q -b main "$REPO"
printf '{"aiDir":".ai","frameworkVersion":"3.0.0"}\n' > "$REPO/.myspec.json"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

payload() {  # payload <hook> -> a payload that reaches the lib lookup
  case "$1" in
    guard-worktree-context) jq -cn --arg c "$REPO" '{tool_name: "Bash", tool_input: {command: "git push"}, cwd: $c, session_id: "lm-1"}' ;;
    *) jq -cn --arg f "$REPO/src/a.ts" --arg c "$REPO" '{tool_name: "Write", tool_input: {file_path: $f, content: "x"}, cwd: $c, session_id: "lm-1", transcript_path: "/nonexistent"}' ;;
  esac
}

# run_without <hook>: sets OUT, ERR and STATUS from a run with the variable unset.
run_without() {
  OUT=$(payload "$1" | env -u CLAUDE_PLUGIN_ROOT bash "$PLUGIN/hooks/$1.sh" 2>"$ROOT/err"); STATUS=$?
  ERR=$(cat "$ROOT/err")
}

for hook in guard-worktree-context require-isolation-decision; do
  run_without "$hook"
  [ "$STATUS" -eq 0 ] && ok || fail "$hook: exits 0 without the variable (got $STATUS)"
  [ "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = deny ] && ok || fail "$hook: denies without the variable (got: ${OUT:0:160})"
  [ "$(printf '%s' "$OUT" | jq -r '.decision' 2>/dev/null)" = block ] && ok || fail "$hook: carries the legacy block field too"
  R=$(printf '%s' "$OUT" | jq -r '.reason' 2>/dev/null)
  printf '%s' "$R" | grep -qF 'CLAUDE_PLUGIN_ROOT' && ok || fail "$hook: the reason names the variable"
  printf '%s' "$R" | grep -qF 'unset' && ok || fail "$hook: the reason says the variable is unset"
  printf '%s' "$R" | grep -qF '/myspec:update' && ok || fail "$hook: the reason names the repair"
  printf '%s' "$ERR" | grep -qF 'myspec lib missing' && ok || fail "$hook: the line also goes to stderr"
done

for hook in validate-frontmatter mark-code-changed no-absolute-paths require-reuse-audit; do
  run_without "$hook"
  [ "$STATUS" -eq 0 ] && ok || fail "$hook: exits 0 without the variable (got $STATUS)"
  [ -z "$OUT" ] && ok || fail "$hook: a PostToolUse hook prints no decision without the variable (got: ${OUT:0:160})"
  printf '%s' "$ERR" | grep -qF 'CLAUDE_PLUGIN_ROOT is unset' && ok || fail "$hook: stderr names the unset variable (got: ${ERR:0:160})"
  printf '%s' "$ERR" | grep -qF '/myspec:update' && ok || fail "$hook: stderr names the repair"
done

run_without record-session-metrics
[ "$STATUS" -eq 0 ] && ok || fail "record-session-metrics: exits 0 without the variable"
[ -z "$OUT" ] && ok || fail "record-session-metrics: prints nothing without the variable"

# A set variable whose lib/ lacks hook-core.sh is the same condition, and the
# reason names the root that was looked under.
mkdir -p "$ROOT/empty-plugin/lib"
OUT=$(payload require-isolation-decision | CLAUDE_PLUGIN_ROOT="$ROOT/empty-plugin" bash "$PLUGIN/hooks/require-isolation-decision.sh" 2>/dev/null)
[ "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = deny ] && ok || fail "a plugin root without lib/hook-core.sh denies"
printf '%s' "$OUT" | jq -r '.reason' | grep -qF "$ROOT/empty-plugin" && ok || fail "the reason names the root it looked under"

# With the variable set to the plugin, the same payloads reach the hook's own
# logic: the isolation gate asks, the Bash guard allows a push with no decision.
OUT=$(payload require-isolation-decision | CLAUDE_PLUGIN_ROOT="$PLUGIN" bash "$PLUGIN/hooks/require-isolation-decision.sh" 2>/dev/null)
printf '%s' "$OUT" | grep -qF 'no work-isolation decision' && ok || fail "with the variable set the isolation hook runs its own gate (got: ${OUT:0:160})"
printf '%s' "$OUT" | grep -qF 'myspec lib missing' && fail "with the variable set no lib-missing reason is printed" || ok

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
