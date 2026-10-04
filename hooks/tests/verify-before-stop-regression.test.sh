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
#   (utf8)   macOS awk exits 2 on invalid UTF-8 in a failing check's log
#            ("towc: multibyte conversion failure"); under set -e the hook
#            died before deciding, and the EXIT trap still recorded
#            `verified`, so the next stop approved. Attribution's awk runs
#            under LC_ALL=C, and `verified` is recorded only after a
#            decision was printed.
#   (once)   attribute_failures ran session_files again, a second jq pass
#            over the state file per failing checkout for the list the root
#            loop already exported as MYSPEC_SESSION_FILES (#254 review).
#   (lib)    A hook installed without the settings reader read the checks
#            its own way and refused every runIn check; it now blocks once
#            with the repair.
#   (#257)   The MYSPEC_STOP_HOOK_ACTIVE guard was dropped while the gate
#            still exported the variable to its checks, so a check that
#            started a nested claude session ran the whole gate inside it.
#            The variable in the hook's own environment approves again.
#   (utf8)   macOS awk exits 2 on invalid UTF-8 in a failing check's log
#            ("towc: multibyte conversion failure"); under set -e the hook
#            died before deciding, and the EXIT trap still recorded
#            `verified`, so the next stop approved. Attribution's awk runs
#            under LC_ALL=C, and `verified` is recorded only after a
#            decision was printed. Pre-existing on main.
#   (pipefail) The memory and setup conformance gates were armed by
#            `git status --porcelain | grep -q .`. grep exits on the first
#            line, so a status longer than a pipe buffer killed git with
#            SIGPIPE, pipefail made the `if` false, and the gate was skipped.
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
RAN="$ROOT/ran"
trap 'rm -rf "$ROOT"' EXIT
SESSION_EVENT="$(cd "$(dirname "$HOOK")" && pwd)/../lib/session-event.sh"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

# Two failing checks; each leaves a trace so a skipped run is visible.
printf '{"checks":[{"name":"alpha","command":"touch %s; echo ALPHA-OUT; exit 1","required":true},{"name":"beta","command":"echo BETA-OUT; exit 1","required":true}]}\n' \
  "$RAN" > "$REPO/.claude/verification.json"

# also_wrote <root> <rel>: a code write, recorded the way mark-code-changed.sh
# records it (lib/session-event.sh), in the state file of <root>'s repository.
also_wrote() {
  bash "$SESSION_EVENT" --root "$1" append "$SID" "$(jq -nc --arg r "$1" --arg p "$2" '{t: "write", root: $r, rel: $p, kind: "code"}')"
}

run_hook() {  # run_hook <extra stdin json fields> -> hook stdout
  also_wrote "$REPO" src/edited.ts
  rm -f "$RAN"
  printf '{"session_id":"%s","cwd":"%s"%s}' "$SID" "$REPO" "$1" | bash "$HOOK" 2>/dev/null
}

decision() { printf '%s' "$1" | jq -r '.decision // "none"' 2>/dev/null || printf 'not-json'; }
reason()   { printf '%s' "$1" | jq -r '.reason // ""' 2>/dev/null; }

# --- 4eb8ccb: stop_hook_active in stdin approves without re-running checks ----
OUT=$(run_hook ',"stop_hook_active":true')
[ "$(decision "$OUT")" = approve ] && ok || fail "stop_hook_active:true approves (got: ${OUT:0:200})"
[ ! -e "$RAN" ] && ok || fail "stop_hook_active:true runs no check"

# --- #257: MYSPEC_STOP_HOOK_ACTIVE in the hook's own environment approves ------
# The gate exports it to its checks: a nested session a check started stops
# without running the gate again.
OUT=$(also_wrote "$REPO" src/edited.ts; rm -f "$RAN"; printf '{"session_id":"%s","cwd":"%s"}' "$SID" "$REPO" \
  | MYSPEC_STOP_HOOK_ACTIVE=1 bash "$HOOK" 2>/dev/null)
[ "$(decision "$OUT")" = approve ] && ok || fail "MYSPEC_STOP_HOOK_ACTIVE in the environment approves (got: ${OUT:0:200})"
[ ! -e "$RAN" ] && ok || fail "MYSPEC_STOP_HOOK_ACTIVE in the environment runs no check"
case "$OUT" in *MYSPEC_STOP_HOOK_ACTIVE*) ok ;; *) fail "the approve names why (got: ${OUT:0:200})" ;; esac
OUT=$(also_wrote "$REPO" src/edited.ts; rm -f "$RAN"; printf '{"session_id":"%s","cwd":"%s"}' "$SID" "$REPO" | CLAUDE_STOP_HOOK_ACTIVE=1 bash "$HOOK" 2>/dev/null)
[ "$(decision "$OUT")" = block ] && ok || fail "CLAUDE_STOP_HOOK_ACTIVE, which the harness never sets, is not a re-entry (got: ${OUT:0:200})"

# --- 4eb8ccb: the failure report is readable ----------------------------------
OUT=$(run_hook '')
[ "$(decision "$OUT")" = block ] && ok || fail "two failing checks block (got: ${OUT:0:200})"
[ -e "$RAN" ] && ok || fail "without stop_hook_active the checks run"
R=$(reason "$OUT")
printf '%s' "$R" | grep -qF 'alpha, beta' && ok || fail "failed check names are joined with \", \" (got: $(printf '%s' "$R" | head -1))"
printf '%s\n' "$R" | grep -qx -- '---' && ok || fail "per-check sections are separated by a --- line"
# shellcheck disable=SC1003 # '\' is a lone literal backslash, not an escaped quote
printf '%s' "$R" | grep -qF '\' && fail "the report holds no literal backslash (got: $(printf '%s' "$R" | grep -F '\' | head -1))" || ok
printf '%s\n' "$R" | grep -qx 'ALPHA-OUT' && ok || fail "check output starts on its own line"
printf '%s\n' "$R" | grep -qx 'BETA-OUT' && ok || fail "the second check's output is reported too"

# --- a missing lib blocks with the repair, once -------------------------------
# The libs ship with the hook; without one the gate does not guess at the
# checks. A copy of the hook beside a lib/ that lacks the settings reader.
BROKEN="$ROOT/broken"
mkdir -p "$BROKEN/hooks"
cp "$HOOK" "$BROKEN/hooks/"
cp -R "$(cd "$(dirname "$HOOK")/.." && pwd)/lib" "$BROKEN/lib"
rm "$BROKEN/lib/myspec-config.sh"
OUT=$(printf '{"session_id":"%s","cwd":"%s"}' "$SID" "$REPO" | CLAUDE_PLUGIN_ROOT=/nonexistent bash "$BROKEN/hooks/verify-before-stop.sh" 2>/dev/null)
[ "$(decision "$OUT")" = block ] && ok || fail "a missing settings reader blocks (got: ${OUT:0:200})"
reason "$OUT" | grep -qF 'myspec lib missing, run /myspec:update' && ok || fail "the block says how to repair the install (got: $(reason "$OUT"))"
reason "$OUT" | grep -qF 'myspec-config.sh' && ok || fail "the block names the missing lib"
OUT=$(printf '{"session_id":"%s","cwd":"%s","stop_hook_active":true}' "$SID" "$REPO" | bash "$BROKEN/hooks/verify-before-stop.sh" 2>/dev/null)
[ "$(decision "$OUT")" = approve ] && ok || fail "a missing lib blocks once: the continuation approves (got: ${OUT:0:200})"

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
wrote() {  # wrote <root> <rel>...: a fresh session-state file of code writes
  local root="$1" p
  shift
  rm -f "$REPO/.claude/state/sessions/$SID.jsonl"
  for p in "$@"; do also_wrote "$root" "$p"; done
}
run_ledger() {  # run_ledger -> hook stdout
  printf '{"session_id":"%s","cwd":"%s"}' "$SID" "$REPO" | bash "$HOOK" 2>/dev/null
}

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

# --- (utf8) invalid UTF-8 in a failing check's output still decides ----------
# An unrelated uncommitted file sends the failure through attribution, whose
# awk reads the check's log.
INV="$ROOT/invalid-utf8"
mkdir -p "$INV/.claude" "$INV/src"
git init -q -b main "$INV"
git -C "$INV" config user.email t@t
git -C "$INV" config user.name t
printf '.claude/state/\n' > "$INV/.gitignore"
# shellcheck disable=SC2016 # the check's own printf, run by the gate
jq -n '{checks: [{name: "bytes", command: "printf \u0027\\377\\376 src/x.ts broken\\n\u0027; exit 1", required: true}]}' > "$INV/.claude/verification.json"
: > "$INV/src/a.ts"
git -C "$INV" add -A && git -C "$INV" commit -q -m init
printf 'x\n' > "$INV/other.ts"
inv_events() { bash "$SESSION_EVENT" --root "$INV" events "$SID-inv$1" | jq -r 'select(.t == "verified") | .root'; }
inv_run() {  # inv_run <sid suffix> <hook> -> stdout; stderr to $ROOT/inv.err, exit to $ROOT/inv.rc
  bash "$SESSION_EVENT" --root "$INV" append "$SID-inv$1" "$(jq -nc --arg r "$INV" '{t: "write", root: $r, rel: "src/a.ts", kind: "code"}')"
  printf '{"session_id":"%s-inv%s","cwd":"%s"}' "$SID" "$1" "$INV" | bash "$2" 2>"$ROOT/inv.err"
  printf '%s' "$?" > "$ROOT/inv.rc"
}
OUT=$(inv_run 1 "$HOOK")
[ "$(cat "$ROOT/inv.rc")" = 0 ] && ok || fail "utf8: the hook exits 0 (got $(cat "$ROOT/inv.rc"): $(cat "$ROOT/inv.err"))"
case "$(decision "$OUT")" in block|approve) ok ;; *) fail "utf8: the hook decides (got: ${OUT:0:200})" ;; esac
grep -qi 'awk' "$ROOT/inv.err" && fail "utf8: no awk error (got: $(cat "$ROOT/inv.err"))" || ok
# An abort before the decision (a report that exits 3) records no verified
# event, so the checkout stays armed.
ABORT="$ROOT/abort"
mkdir -p "$ABORT/hooks"
cp "$HOOK" "$ABORT/hooks/"
cp -R "$(cd "$(dirname "$HOOK")/.." && pwd)/lib" "$ABORT/lib"
printf '\nreport_decision() { exit 3; }\n' >> "$ABORT/lib/stop-gate/report.sh"
OUT=$(inv_run 2 "$ABORT/hooks/verify-before-stop.sh")
[ "$(cat "$ROOT/inv.rc")" = 3 ] && ok || fail "abort: the stubbed report exits 3 (got $(cat "$ROOT/inv.rc"))"
[ -z "$(inv_events 2)" ] && ok || fail "abort: no verified event without a decision (got: $(inv_events 2))"
OUT=$(inv_run 3 "$HOOK")
[ "$(inv_events 3)" = "$INV" ] && ok || fail "a decided run still records verified (got: $(inv_events 3))"
rm -f "$INV/other.ts"

# --- (pipefail) a long status still arms the conformance gates --------------
# Each doctor stub always fails, so the gate must block whenever it is armed.
# About 2000 untracked files directly in a tracked directory give a porcelain
# status well past a 64 KiB pipe buffer.
if command -v node >/dev/null 2>&1; then
  CONF="$ROOT/conformance"
  mkdir -p "$CONF/.claude/lib" "$CONF/.ai/memory" "$CONF/src"
  git init -q -b main "$CONF"
  git -C "$CONF" config user.email t@t
  git -C "$CONF" config user.name t
  printf '{"aiDir":".ai"}\n' > "$CONF/.myspec.json"
  printf '{"checks":[{"name":"ok","command":"true","required":true}]}\n' > "$CONF/.claude/verification.json"
  printf 'process.stdout.write("doctor stub: error\\n"); process.exit(1);\n' > "$CONF/.claude/lib/memory-doctor.mjs"
  printf 'process.stdout.write("setup stub: error\\n"); process.exit(1);\n' > "$CONF/.claude/lib/setup-doctor.mjs"
  : > "$CONF/.ai/memory/index.md"
  : > "$CONF/src/a.ts"
  git -C "$CONF" add -A && git -C "$CONF" commit -q -m init
  conf_run() {
    rm -f "$CONF/.claude/state/sessions/$SID.jsonl"
    also_wrote "$CONF" src/a.ts
    printf '{"session_id":"%s","cwd":"%s"}' "$SID" "$CONF" | bash "$HOOK" 2>/dev/null
  }
  pad=untracked-file-with-a-long-enough-name-to-fill-the-pipe-buffer
  for dir in .ai/memory .claude; do
    i=0
    while [ "$i" -lt 2000 ]; do : > "$CONF/$dir/$pad-$i.md"; i=$((i + 1)); done
    bytes=$(git -C "$CONF" status --porcelain -- "$dir" | wc -c | tr -d ' ')
    [ "$bytes" -gt 65536 ] && ok || fail "the $dir fixture status exceeds a pipe buffer (got $bytes bytes)"
    OUT=$(conf_run)
    [ "$(decision "$OUT")" = block ] && ok || fail "a $bytes-byte status under $dir still runs its conformance doctor (got: ${OUT:0:200})"
    find "$CONF/$dir" -maxdepth 1 -name "$pad-*" -delete
  done
else
  printf 'SKIP  conformance pipefail cases: node not found\n' >&2
fi

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
