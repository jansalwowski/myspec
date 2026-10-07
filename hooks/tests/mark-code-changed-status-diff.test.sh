#!/usr/bin/env bash
# Bash writes found from the working tree, not the command text (#276):
# mark-code-changed.sh captures `git status` (and the changed files' blobs)
# at PreToolUse and records what changed by PostToolUse, alongside what the
# command scanner reads. Covers the issue's repro through the Stop gate, the
# forms the scanner cannot read, the files a call leaves alone, a checkout
# reached by `cd`, what stays out of reach (a gitignored file, a call without
# a tool_use_id, a tree too dirty to capture, a project that turns the diff
# off), and another session's Bash call overlapping this one.
#
# Usage: mark-code-changed-status-diff.test.sh [path-to-hook]

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MARK="${1:-$HERE/../mark-code-changed.sh}"
STOP="$HERE/../verify-before-stop.sh"
# The hooks find their lib through CLAUDE_PLUGIN_ROOT, as the harness exports it.
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$MARK")/.." && pwd)}"

ROOT=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT
SID="sd-$$"
LEAK="/Users/alice/work/x"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

REPO="$ROOT/repo"
STATE="$REPO/.claude/state/sessions"
mkdir -p "$REPO/docs" "$REPO/src"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
printf '{"aiDir":".ai","frameworkVersion":"3.0.0"}\n' > "$REPO/.myspec.json"
printf '.claude/state/\nbuild/\n' > "$REPO/.gitignore"
printf 'one\n' > "$REPO/docs/kept.md"
printf 'export const a = 1\n' > "$REPO/src/a.ts"
git -C "$REPO" add -A
git -C "$REPO" commit -qm init

N=0
# mark <sid> <event> <command> [cwd] [tool_use_id]: the harness's call of the
# hook for a Bash command; the call id is CALL unless given ("" for none).
mark() {
  jq -nc --arg s "$1" --arg e "$2" --arg cmd "$3" --arg c "${4:-$REPO}" --arg id "${5-$CALL}" \
    '{hook_event_name: $e, session_id: $s, tool_name: "Bash", cwd: $c, tool_input: {command: $cmd}}
     + (if $id != "" then {tool_use_id: $id} else {} end)' | bash "$MARK" >/dev/null 2>&1
}

# bashcall <sid> <command> [cwd] [tool_use_id]: PreToolUse, the command,
# PostToolUse, as the harness runs a Bash call.
bashcall() {
  N=$((N + 1))
  CALL="toolu_$N"
  mark "$1" PreToolUse "$2" "${3:-$REPO}" "${4-$CALL}"
  (cd "${3:-$REPO}" && eval "$2") >/dev/null 2>&1
  mark "$1" PostToolUse "$2" "${3:-$REPO}" "${4-$CALL}"
}

# written <sid> -> the session's write events as `<kind> <rel>` lines.
written() {
  jq -r 'select(.t == "write") | "\(.kind) \(.rel)"' "$STATE/$1.jsonl" 2>/dev/null | LC_ALL=C sort -u | tr '\n' ','
}
has() { case ",$(written "$1")" in *",$2,"*) return 0 ;; esac; return 1; }

stop() { jq -nc --arg s "$1" --arg c "$REPO" '{session_id: $s, cwd: $c}' | bash "$STOP" 2>/dev/null; }
decision() { printf '%s' "$1" | jq -r '.decision // "none"' 2>/dev/null; }

# --- the issue's repro: a variable path, caught at Stop -----------------------
bashcall "$SID-1" "f=docs/a.md; printf 'see $LEAK\n' >> \"\$f\""
has "$SID-1" "file docs/a.md" && ok || fail "a write to a variable path is recorded (got: $(written "$SID-1"))"
OUT=$(stop "$SID-1")
[ "$(decision "$OUT")" = block ] && ok || fail "a leak written through a variable path blocks the stop (got: ${OUT:0:200})"
case "$OUT" in *docs/a.md*) ok ;; *) fail "the block names docs/a.md" ;; esac
rm -f "$REPO/docs/a.md"

# --- an interpreter's write, and a code file --------------------------------------
bashcall "$SID-2" "awk 'BEGIN { print \"export const b = 2\" > \"src/b.ts\" }'"
has "$SID-2" "code src/b.ts" && ok || fail "a file awk writes is a code write (got: $(written "$SID-2"))"
[ -f "$STATE/$SID-2.md" ] && ok || fail "a code write found by the diff opens the session log"
git -C "$REPO" add src/b.ts && git -C "$REPO" commit -qm b

# --- what a call leaves alone is not its write --------------------------------------
printf 'other session, uncommitted\n' >> "$REPO/docs/kept.md"
printf 'untracked before\n' > "$REPO/docs/before.md"
bashcall "$SID-3" "ls docs; git add docs/before.md"
[ -z "$(written "$SID-3")" ] && ok || fail "files dirty before the call and unchanged by it are not written (got: $(written "$SID-3"))"
bashcall "$SID-3" "f=docs/kept.md; printf 'clean line\n' >> \"\$f\""
[ "$(written "$SID-3")" = "file docs/kept.md," ] && ok || fail "a dirty file written again is recorded (got: $(written "$SID-3"))"
printf 'old %s\n' "$LEAK" >> "$REPO/docs/before.md"
bashcall "$SID-4" "f=docs/before.md; printf 'clean line\n' >> \"\$f\""
OUT=$(stop "$SID-4")
[ "$(decision "$OUT")" = approve ] && ok || fail "an uncommitted leak from before the call is not this call's (got: ${OUT:0:200})"
git -C "$REPO" checkout -q -- docs/kept.md
git -C "$REPO" rm -q -f --cached docs/before.md
rm -f "$REPO/docs/before.md"

# --- a deletion -------------------------------------------------------------------
bashcall "$SID-5" "f=src/b.ts; rm \"\$f\""
has "$SID-5" "code src/b.ts" && ok || fail "a deleted code file is a code write (got: $(written "$SID-5"))"
git -C "$REPO" checkout -q -- src/b.ts

# --- the capture lives for the call only -----------------------------------------
ls "$STATE/$SID-5.bash/$CALL".* >/dev/null 2>&1 && fail "the capture is gone after PostToolUse" || ok
tail -1 "$STATE/bash-calls.log" | grep -q " end $SID-5 $CALL\$" && ok || fail "the call's end is in the call log"

# --- a linked worktree reached by cd ------------------------------------------------
WT="$ROOT/wt"
git -C "$REPO" worktree add -q -b wt "$WT"
bashcall "$SID-6" "cd \"$WT\" && f=docs/w.md && printf 'w\n' > \"\$f\""
jq -e --arg r "$WT" 'select(.t == "write" and .root == $r and .rel == "docs/w.md")' "$STATE/$SID-6.jsonl" >/dev/null 2>&1 \
  && ok || fail "a write in a worktree a literal cd reaches is recorded under its root"

# --- out of reach -----------------------------------------------------------------
mkdir -p "$REPO/build"
bashcall "$SID-7" "f=build/out.ts; printf 'x\n' > \"\$f\""
[ -z "$(written "$SID-7")" ] && ok || fail "a gitignored file never shows in git status (got: $(written "$SID-7"))"
bashcall "$SID-7" "printf 'x\n' > build/out.ts"
has "$SID-7" "code build/out.ts" && ok || fail "the scanner still records a gitignored file it can read"
bashcall "$SID-8" "f=docs/n.md; printf 'n\n' > \"\$f\"" "$REPO" ""
[ -z "$(written "$SID-8")" ] && ok || fail "without a tool_use_id there is no diff (got: $(written "$SID-8"))"
rm -f "$REPO/docs/n.md"
for i in 1 2 3; do printf 'u\n' > "$REPO/u$i.txt"; done
STATUS_DIFF_MAX=2 bashcall "$SID-9" "f=docs/n.md; printf 'n\n' > \"\$f\""
[ -z "$(written "$SID-9")" ] && ok || fail "a tree above STATUS_DIFF_MAX is not diffed (got: $(written "$SID-9"))"
rm -f "$REPO"/u?.txt "$REPO/docs/n.md"

# --- a project that turns the status diff off -------------------------------------
cp "$REPO/.myspec.json" "$ROOT/myspec.json.bak"
printf '{"aiDir":".ai","frameworkVersion":"3.0.0","hooks":{"markCodeChanged":{"statusDiff":false}}}\n' > "$REPO/.myspec.json"
bashcall "$SID-18" "f=docs/n.md; printf 'n\n' > \"\$f\"; printf 'm\n' > docs/m.md"
[ "$(written "$SID-18")" = "file docs/m.md," ] && ok \
  || fail "hooks.markCodeChanged.statusDiff false leaves the scanner's targets only (got: $(written "$SID-18"))"
grep -q " $SID-18 " "$STATE/bash-calls.log" 2>/dev/null && fail "a call with the status diff off is not in the call log" || ok
ls "$STATE/$SID-18.bash/$CALL".* >/dev/null 2>&1 && fail "a call with the status diff off leaves no capture" || ok
cp "$ROOT/myspec.json.bak" "$REPO/.myspec.json"
rm -f "$REPO/docs/n.md" "$REPO/docs/m.md"

# --- another session's Bash call overlapping this one ---------------------------------
LOG="$STATE/bash-calls.log"
logline() { printf '%s %s %s %s\n' "${4:-$(date +%s)}" "$1" "$2" "$3" >> "$LOG"; }
# Open when this call starts.
logline start other toolu_open
bashcall "$SID-10" "f=docs/o.md; printf 'o\n' > \"\$f\"; printf 'p\n' > docs/p.md"
[ "$(written "$SID-10")" = "file docs/p.md," ] && ok \
  || fail "while another session's call is open only the scanner's targets count (got: $(written "$SID-10"))"
logline end other toolu_open
rm -f "$REPO/docs/o.md" "$REPO/docs/p.md"
# Started and ended while this call ran.
N=$((N + 1)); CALL="toolu_$N"
CMD="f=docs/o.md; printf 'o\n' > \"\$f\""
mark "$SID-11" PreToolUse "$CMD"
(cd "$REPO" && eval "$CMD")
logline start other toolu_inside
logline end other toolu_inside
mark "$SID-11" PostToolUse "$CMD"
[ -z "$(written "$SID-11")" ] && ok || fail "another session's call inside this one blocks the diff (got: $(written "$SID-11"))"
rm -f "$REPO/docs/o.md"
# Ended before this call started, in the same second: the log orders it.
logline start other toolu_before
logline end other toolu_before
bashcall "$SID-12" "f=docs/o.md; printf 'o\n' > \"\$f\""
has "$SID-12" "file docs/o.md" && ok || fail "a call that ended before this one started does not overlap (got: $(written "$SID-12"))"
rm -f "$REPO/docs/o.md"
# Opened over 15 minutes ago and never ended: a call that died.
logline start other toolu_dead "$(( $(date +%s) - 3600 ))"
bashcall "$SID-13" "f=docs/o.md; printf 'o\n' > \"\$f\""
has "$SID-13" "file docs/o.md" && ok || fail "a call open for over 15 minutes is ignored (got: $(written "$SID-13"))"
rm -f "$REPO/docs/o.md"
# A subagent of the same session: its calls are the session's own.
logline start "$SID-14" toolu_sub
bashcall "$SID-14" "f=docs/o.md; printf 'o\n' > \"\$f\""
has "$SID-14" "file docs/o.md" && ok || fail "the session's own open call does not block its diff (got: $(written "$SID-14"))"
rm -f "$REPO/docs/o.md"
# This call's start is not in the log (rotated twice, removed): nothing can be told.
N=$((N + 1)); CALL="toolu_$N"
mark "$SID-15" PreToolUse "$CMD"
(cd "$REPO" && eval "$CMD")
rm -f "$LOG"
mark "$SID-15" PostToolUse "$CMD"
[ -z "$(written "$SID-15")" ] && ok || fail "a call whose start is not in the log is not diffed (got: $(written "$SID-15"))"
rm -f "$REPO/docs/o.md"
# The log rotates past 256 KiB, and a call started before the rotation is still found.
N=$((N + 1)); CALL="toolu_$N"
mark "$SID-16" PreToolUse "$CMD"
(cd "$REPO" && eval "$CMD")
mv "$LOG" "$LOG.old"
mark "$SID-16" PostToolUse "$CMD"
has "$SID-16" "file docs/o.md" && ok || fail "a call whose start was rotated to bash-calls.log.old is still diffed (got: $(written "$SID-16"))"
rm -f "$REPO/docs/o.md"
head -c 300000 /dev/zero | tr '\0' 'x' > "$LOG"
mkdir -p "$STATE/$SID-17.bash"
: > "$STATE/$SID-17.bash/toolu_stale.0"
touch -t 200001010000 "$STATE/$SID-17.bash/toolu_stale.0"
: > "$STATE/$SID-17.bash/toolu_fresh.0"
bashcall "$SID-17" "true"
[ "$(wc -l < "$LOG" | tr -d ' ')" = 2 ] && ok || fail "a log past 256 KiB is rotated at the next start"
[ ! -e "$STATE/$SID-17.bash/toolu_stale.0" ] && ok || fail "the rotation sweeps a capture older than an hour"
[ -e "$STATE/$SID-17.bash/toolu_fresh.0" ] && ok || fail "the rotation keeps a younger capture"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
