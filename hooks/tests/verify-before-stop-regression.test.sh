#!/usr/bin/env bash
# Regression fixture for verify-before-stop.sh fixes the other fixtures
# (verify-before-stop*.test.sh) do not cover. One case per past fix:
#
#   4eb8ccb  The re-entry guard read env vars the harness never sets, so the
#            continuation after a block re-ran every check; the harness sends
#            stop_hook_active in the stdin JSON. The failure report joined
#            names with a multi-char IFS (only its first character is used)
#            and wrote "\n" inside double quotes, so the agent got
#            "a,b" and literal backslashes instead of "a, b" and separators.
#   (doctor) Checks ran in the cwd's checkout only, so a session whose cwd was
#            the clean main checkout but whose edits were in a linked worktree
#            verified the untouched tree and passed. The checkouts to verify
#            now come from the session log's `## Files touched`.
#
# Usage: verify-before-stop-regression.test.sh [path-to-hook]

set -uo pipefail

HOOK="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../verify-before-stop.sh}"

if [ ! -f "$HOOK" ]; then
  echo "FATAL: hook not found: $HOOK" >&2
  exit 1
fi

ROOT=$(cd "$(mktemp -d)" && pwd -P)
REPO="$ROOT/checkout"
mkdir -p "$REPO/.claude"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
git -C "$REPO" commit -q --allow-empty -m init
SID="vbs-regression-$$"
CHANGED="/tmp/.myspec-code-changed-$SID"
RAN="$ROOT/ran"
LEDGER="/tmp/.myspec-session-writes-$SID"
trap 'rm -rf "$ROOT"; rm -f "$CHANGED" "$LEDGER"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

# Two failing checks; each leaves a trace so a skipped run is visible.
printf '{"checks":[{"name":"alpha","command":"touch %s; echo ALPHA-OUT; exit 1","required":true},{"name":"beta","command":"echo BETA-OUT; exit 1","required":true}]}\n' \
  "$RAN" > "$REPO/.claude/verification.json"

run_hook() {  # run_hook <extra stdin json fields> -> hook stdout
  touch "$CHANGED"
  rm -f "$RAN"
  printf '{"session_id":"%s","cwd":"%s"%s}' "$SID" "$REPO" "$1" | bash "$HOOK" 2>/dev/null
}

decision() { printf '%s' "$1" | jq -r '.decision // "none"' 2>/dev/null || printf 'not-json'; }
reason()   { printf '%s' "$1" | jq -r '.reason // ""' 2>/dev/null; }

# --- 4eb8ccb: stop_hook_active in stdin approves without re-running checks ----
OUT=$(run_hook ',"stop_hook_active":true')
[ "$(decision "$OUT")" = approve ] && ok || fail "stop_hook_active:true approves (got: ${OUT:0:200})"
[ ! -e "$RAN" ] && ok || fail "stop_hook_active:true runs no check"

# --- 4eb8ccb: the failure report is readable ----------------------------------
OUT=$(run_hook '')
[ "$(decision "$OUT")" = block ] && ok || fail "two failing checks block (got: ${OUT:0:200})"
[ -e "$RAN" ] && ok || fail "without stop_hook_active the checks run"
R=$(reason "$OUT")
printf '%s' "$R" | grep -qF 'alpha, beta' && ok || fail "failed check names are joined with \", \" (got: $(printf '%s' "$R" | head -1))"
printf '%s\n' "$R" | grep -qx -- '---' && ok || fail "per-check sections are separated by a --- line"
printf '%s' "$R" | grep -qF '\' && fail "the report holds no literal backslash (got: $(printf '%s' "$R" | grep -F '\' | head -1))" || ok
printf '%s\n' "$R" | grep -qx 'ALPHA-OUT' && ok || fail "check output starts on its own line"
printf '%s\n' "$R" | grep -qx 'BETA-OUT' && ok || fail "the second check's output is reported too"

# --- (#201) the checkout the session edited is the one verified -------------
# The worktree carries a marker file that makes its copy of the check fail;
# the main checkout (the cwd) stays clean and passes. The ledger names the
# checkouts the session wrote code in (docs/stop-gate.md).
printf '{"checks":[{"name":"tree","command":"test ! -f BROKEN","required":true}]}\n' > "$REPO/.claude/verification.json"
printf '.claude/state/\n' > "$REPO/.gitignore"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m checks
WT="$ROOT/wt"
git -C "$REPO" worktree add -q -b wt "$WT"
mkdir -p "$WT/src" "$REPO/.claude/state/sessions"
touch "$WT/BROKEN" "$WT/src/a.ts"
wrote() {  # wrote <root> <rel>...: a fresh ledger of code writes
  local root="$1" p
  shift
  : > "$LEDGER"
  for p in "$@"; do printf 'code\t%s\t%s\n' "$root" "$p" >> "$LEDGER"; done
}
also_wrote() { printf 'code\t%s\t%s\n' "$1" "$2" >> "$LEDGER"; }
run_ledger() {  # run_ledger -> hook stdout, armed by the ledger alone
  rm -f "$CHANGED"
  printf '{"session_id":"%s","cwd":"%s"}' "$SID" "$REPO" | bash "$HOOK" 2>/dev/null
}

rm -f "$LEDGER"
OUT=$(run_hook '')
[ "$(decision "$OUT")" = approve ] && ok || fail "legacy marker, no ledger: the cwd checkout is verified, as before (got: ${OUT:0:200})"

wrote "$WT" src/a.ts
OUT=$(run_ledger)
[ "$(decision "$OUT")" = block ] && ok || fail "edits in a worktree verify the worktree, not the clean cwd checkout (got: ${OUT:0:200})"
reason "$OUT" | grep -qF "[in $WT]" && ok || fail "the report names the checkout the check ran in"

rm -f "$WT/BROKEN"
touch "$REPO/BROKEN"
wrote "$WT" src/a.ts
OUT=$(run_ledger)
[ "$(decision "$OUT")" = approve ] && ok || fail "a checkout the session never touched is not verified (got: ${OUT:0:200})"

wrote "$WT" src/a.ts
also_wrote "$REPO" src/b.ts
OUT=$(run_ledger)
[ "$(decision "$OUT")" = block ] && ok || fail "edits in both checkouts verify both (got: ${OUT:0:200})"
OUT=$(run_ledger)
[ "$(decision "$OUT")" = approve ] && ok || fail "a verified checkout is not re-run without a new write (got: ${OUT:0:200})"
rm -f "$REPO/BROKEN"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
