#!/usr/bin/env bash
# Fixture for lib/session-event.sh, the session-state file
# (.claude/state/sessions/<session_id>.jsonl in the main checkout) that
# replaced the /tmp write ledger, the legacy code-changed marker, the
# isolation markers and the feature-implement marker.
#
# Covers: append and read, a truncated last line, concurrent appends, where
# the file lives (main checkout, submodule's superproject, no git), the
# arming and attribution queries, TTL expiry of the isolation decision and the
# implement state, per-session isolation (a subagent shares its parent's id;
# another session's decision is never read), and the one-time import of the
# legacy /tmp ledger.
#
# Usage: session-event.test.sh [path-to-session-event.sh]

set -uo pipefail

LIB="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../session-event.sh}"
if [ ! -f "$LIB" ]; then
  echo "FATAL: session-event.sh not found: $LIB" >&2
  exit 1
fi
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is required" >&2; exit 1; }
# shellcheck source=lib/session-event.sh
. "$LIB"

ROOT=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT
# The legacy ledger directory, redirected so the test never touches /tmp.
SESSION_LEGACY_LEDGER_DIR="$ROOT/legacy"
mkdir -p "$SESSION_LEGACY_LEDGER_DIR"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }
eq() { if [ "$1" = "$2" ]; then ok; else fail "$3 (want '$2', got '$1')"; fi; }

git_() { git -c user.email=t@t -c user.name=t -c protocol.file.allow=always "$@"; }
new_repo() { git_ init -q -b main "$1" && git_ -C "$1" commit -q --allow-empty -m init; }

REPO="$ROOT/repo"
new_repo "$REPO"
printf '{}\n' > "$REPO/.myspec.json"
FILE="$REPO/.claude/state/sessions"

# --- append and read --------------------------------------------------------------

session_append "$REPO" s1 '{"t":"write","root":"/r","rel":"a.ts","kind":"code"}' && ok || fail "append: an event is written"
eq "$(wc -l < "$FILE/s1.jsonl" | tr -d ' ')" 1 "append: one line per event"
eq "$(jq -r '.at | type' "$FILE/s1.jsonl")" number "append: at is set"
eq "$(session_events "$REPO" s1 | jq -r .rel)" a.ts "events: the event reads back"
session_append "$REPO" s1 'not json' && fail "append: a non-object is refused" || ok
session_append "$REPO" s1 '{"rel":"x"}' && fail "append: an event without t is refused" || ok
session_append "$REPO" '../x' '{"t":"write"}' && fail "append: an id with a slash is refused" || ok
session_append "$REPO" '' '{"t":"write"}' && fail "append: an empty id is refused" || ok
eq "$(session_events "$REPO" nobody)" "" "events: no file reads as no events"

# CLI: --root picks the checkout; implement records nothing itself.
bash "$LIB" --root "$REPO" append s2 '{"t":"verified","root":"/r"}' && ok || fail "cli: append"
eq "$(bash "$LIB" --root "$REPO" events s2 | jq -r .t)" verified "cli: events"
OUT=$(cd "$REPO" && bash "$LIB" implement start)
case "$OUT" in *mark-code-changed*) ok ;; *) fail "cli: implement names the hook that records it (got: $OUT)" ;; esac
bash "$LIB" implement sideways >/dev/null 2>&1 && fail "cli: implement takes start or stop only" || ok

# --- a truncated last line ----------------------------------------------------------

session_append "$REPO" s3 '{"t":"write","root":"/r","rel":"one.ts","kind":"code"}'
printf '{"t":"write","root":"/r","rel":"cut' >> "$FILE/s3.jsonl"
eq "$(session_events "$REPO" s3 | jq -r .rel | tr '\n' ' ')" "one.ts " "truncated: the cut line is skipped"
session_append "$REPO" s3 '{"t":"write","root":"/r","rel":"two.ts","kind":"code"}'
eq "$(session_events "$REPO" s3 | jq -r .rel | tr '\n' ' ')" "one.ts two.ts " "truncated: the next append starts on a fresh line"

# --- concurrent appends ---------------------------------------------------------------

# Each writer waits at a barrier, so the 20 appends land together.
LONG=$(printf 'd%.0s' $(seq 1 300))
GO="$ROOT/go"
for i in $(seq 1 20); do
  (
    while [ ! -e "$GO" ]; do sleep 0.01; done
    session_append "$REPO" s4 "{\"t\":\"write\",\"root\":\"/r\",\"rel\":\"$LONG/f$i.ts\",\"kind\":\"code\",\"agent\":\"a$i\"}"
  ) &
done
sleep 0.5
touch "$GO"
wait
eq "$(wc -l < "$FILE/s4.jsonl" | tr -d ' ')" 20 "concurrent: 20 writers leave 20 lines"
eq "$(jq -c . "$FILE/s4.jsonl" 2>/dev/null | wc -l | tr -d ' ')" 20 "concurrent: every line parses"
eq "$(session_events "$REPO" s4 | jq -r .agent | sort -u | wc -l | tr -d ' ')" 20 "concurrent: every writer's event is intact"

# --- where the file lives -------------------------------------------------------------

WT="$ROOT/wt"
git_ -C "$REPO" worktree add -q -b wt "$WT"
eq "$(session_home "$WT/sub/dir")" "$REPO" "home: a linked worktree files with its main checkout"
MOD="$ROOT/modsrc"
new_repo "$MOD"
git_ -C "$REPO" submodule add -q "$MOD" mod >/dev/null 2>&1
eq "$(session_home "$REPO/mod")" "$REPO" "home: a submodule files with its superproject"
mkdir -p "$ROOT/nogit/a/b"
printf '{}\n' > "$ROOT/nogit/.myspec.json"
eq "$(session_home "$ROOT/nogit/a/b")" "$ROOT/nogit" "home: without git, the nearest .myspec.json"
session_home "$ROOT/legacy" >/dev/null && fail "home: no checkout and no .myspec.json has none" || ok
session_tracked "$REPO" && ok || fail "tracked: a myspec project"
# A repository with no main checkout git can name (a bare clone with
# worktrees, a --separate-git-dir checkout) files every worktree's events in
# one place, under its common dir.
BARE="$ROOT/bare.git"
new_repo "$ROOT/bare-src"
git_ clone -q --bare "$ROOT/bare-src" "$BARE"
git_ -C "$BARE" worktree add -q -b ba "$ROOT/bare-a" >/dev/null 2>&1
git_ -C "$BARE" worktree add -q -b bb "$ROOT/bare-b" >/dev/null 2>&1
BARE_P=$(cd "$BARE" && pwd -P)
eq "$(session_home "$ROOT/bare-a")" "$BARE_P" "home: a bare repository's worktree files under its common dir"
eq "$(session_home "$ROOT/bare-b")" "$(session_home "$ROOT/bare-a")" "home: every worktree of a bare repository shares it"
eq "$(session_file "$(session_home "$ROOT/bare-a")" s1)" "$BARE_P/myspec-state/sessions/s1.jsonl" "file: under the common dir, not in a worktree"
SEP="$ROOT/sep"
git_ init -q -b main --separate-git-dir "$ROOT/sep.gitdir" "$SEP"
git_ -C "$SEP" commit -q --allow-empty -m init
git_ -C "$SEP" worktree add -q -b sw "$ROOT/sep-wt" >/dev/null 2>&1
eq "$(session_file "$(session_home "$ROOT/sep-wt")" s1)" "$(session_file "$(session_home "$SEP")" s1)" "file: a --separate-git-dir checkout and its worktree share one"
eq "$(session_file "$SEP" s1)" "$(session_file "$(session_home "$SEP")" s1)" "file: a reader given the checkout itself finds the same file"
session_tracked "$MOD" && fail "tracked: a repository with neither .myspec.json nor a stop gate is not" || ok

# --- arming and attribution queries ------------------------------------------------------

S=s5
session_append "$REPO" $S "$(jq -nc --arg r "$REPO" '{t:"write",root:$r,rel:"a.ts",kind:"code"}')"
session_append "$REPO" $S "$(jq -nc --arg r "$WT" '{t:"write",root:$r,rel:"b.ts",kind:"code"}')"
session_append "$REPO" $S "$(jq -nc --arg r "$REPO" '{t:"write",root:$r,rel:"tsconfig.json",kind:"file"}')"
session_append "$REPO" $S "$(jq -nc --arg r "$REPO/mod" '{t:"write",root:$r,rel:"m.ts",kind:"code",agent:"a1"}')"
eq "$(session_armed_roots "$REPO" $S | tr '\n' ' ')" "$REPO $WT $REPO/mod " "armed: every root with a code write, first-written order"
session_append "$REPO" $S "$(jq -nc --arg r "$REPO" '{t:"verified",root:$r}')"
eq "$(session_armed_roots "$REPO" $S | tr '\n' ' ')" "$WT $REPO/mod " "armed: a verified root is disarmed"
session_append "$REPO" $S "$(jq -nc --arg r "$REPO" '{t:"write",root:$r,rel:"README.md",kind:"file"}')"
eq "$(session_armed_roots "$REPO" $S | head -1)" "$WT" "armed: a file write does not re-arm"
session_append "$REPO" $S "$(jq -nc --arg r "$REPO" '{t:"write",root:$r,rel:"c.ts",kind:"code"}')"
eq "$(session_armed_roots "$REPO" $S | tr '\n' ' ')" "$REPO $WT $REPO/mod " "armed: a code write after the run re-arms, in first-written order"
eq "$(session_written "$REPO" $S "$REPO" | tr '\n' ' ')" "README.md a.ts c.ts mod/m.ts tsconfig.json " "written: code and file, a nested checkout's under its path"
eq "$(session_written "$REPO" $S "$WT")" "b.ts" "written: per checkout"
session_seen "$REPO" $S code "$REPO/mod" m.ts a1 && ok || fail "seen: the same write is recorded"
session_seen "$REPO" $S code "$REPO/mod" m.ts "" && fail "seen: another agent's write is not the same" || ok
session_seen "$REPO" $S code "$REPO" a.ts "" && fail "seen: a write before the root's verified event is not" || ok

# --- TTLs --------------------------------------------------------------------------------

NOW=$(date +%s)
raw() { printf '%s\n' "$2" >> "$FILE/$1.jsonl"; }  # an event with its own "at"

raw iso1 "{\"t\":\"isolation\",\"mode\":\"worktree\",\"path\":\"/wt/p\",\"at\":$((NOW - 60))}"
session_isolation "$REPO" iso1
eq "$ISO_MODE|$ISO_PATH" "worktree|/wt/p" "isolation: the session's decision"
raw iso2 "{\"t\":\"isolation\",\"mode\":\"develop\",\"at\":$((NOW - HOOK_DECISION_TTL - 5))}"
session_isolation "$REPO" iso2
eq "$ISO_MODE" "" "isolation: a decision past the TTL decides nothing"
raw iso3 "{\"t\":\"isolation\",\"mode\":\"develop\",\"at\":$((NOW - 60))}"
raw iso3 "{\"t\":\"isolation\",\"mode\":\"\",\"path\":\"\",\"at\":$((NOW - 30))}"
session_isolation "$REPO" iso3
eq "$ISO_MODE" "" "isolation: a reset (empty mode) clears the decision"
raw iso3 "{\"t\":\"isolation\",\"mode\":\"worktree\",\"at\":$((NOW - 10))}"
session_isolation "$REPO" iso3
eq "$ISO_MODE" "worktree" "isolation: the last event decides"
raw iso4 "{\"t\":\"isolation\",\"mode\":\"develop\",\"at\":\"garbage\"}"
session_isolation "$REPO" iso4
eq "$ISO_MODE" "" "isolation: an unreadable at decides nothing"
session_isolation "$REPO" iso-none
eq "$ISO_MODE" "" "isolation: another session's decision is never read (#146)"

raw imp1 "{\"t\":\"implement\",\"state\":\"start\",\"at\":$((NOW - 60))}"
session_implement_active "$REPO" imp1 && ok || fail "implement: a fresh start is active"
raw imp1 "{\"t\":\"implement\",\"state\":\"stop\",\"at\":$((NOW - 30))}"
session_implement_active "$REPO" imp1 && fail "implement: a stop ends it" || ok
raw imp2 "{\"t\":\"implement\",\"state\":\"start\",\"at\":$((NOW - HOOK_DECISION_TTL - 1))}"
session_implement_active "$REPO" imp2 && fail "implement: a start past the TTL is a crashed run" || ok
raw imp3 "{\"t\":\"implement\",\"state\":\"start\",\"at\":$((NOW + 3600))}"
session_implement_active "$REPO" imp3 && fail "implement: a future-dated start is not active" || ok
raw imp4 '{"t":"implement","state":"start","at":"garbage"}'
session_implement_active "$REPO" imp4 && fail "implement: an unreadable at is not active" || ok
session_implement_active "$REPO" imp1-other && fail "implement: another session's run does not count" || ok

# --- legacy /tmp ledger import --------------------------------------------------------------

LEGACY="$SESSION_LEGACY_LEDGER_DIR/.myspec-session-writes-old1"
printf 'code\t%s\ta.ts\nfile\t%s\tpkg.json\tagent-7\nverified\t%s\t-\ncode\t%s\tb.ts\n' "$REPO" "$REPO" "$REPO" "$WT" > "$LEGACY"
eq "$(session_armed_roots "$REPO" old1 | tr '\n' ' ')" "$WT " "legacy: the ledger is imported on first read, verified lines included"
[ ! -e "$LEGACY" ] && [ -f "$LEGACY.imported" ] && ok || fail "legacy: the old ledger is renamed .imported"
eq "$(session_events "$REPO" old1 | jq -r 'select(.rel == "pkg.json") | .agent + " " + .kind')" "agent-7 file" "legacy: kind and agent are kept"
printf 'code\t%s\tlate.ts\n' "$REPO" > "$LEGACY"
session_append "$REPO" old1 "$(jq -nc --arg r "$REPO" '{t:"write",root:$r,rel:"new.ts",kind:"file"}')"
eq "$(session_written "$REPO" old1 "$REPO" | tr '\n' ' ')" "a.ts new.ts pkg.json " "legacy: imported once, never again once the file exists"
[ -f "$LEGACY" ] && ok || fail "legacy: a ledger met after the import is left alone"
LEGACY2="$SESSION_LEGACY_LEDGER_DIR/.myspec-session-writes-old2"
printf 'code\t%s\tw.ts\n' "$REPO" > "$LEGACY2"
session_append "$REPO" old2 "$(jq -nc --arg r "$REPO" '{t:"verified",root:$r}')"
eq "$(session_events "$REPO" old2 | jq -r .t | tr '\n' ' ')" "write verified " "legacy: an append imports first, so old writes come first"

# --- legacy implement and isolation markers --------------------------------------------------
# A session upgraded mid feature-implement keeps its run: a fresh
# implement-in-progress.json becomes an implement start, and the session's
# own isolation marker an isolation event, each imported once.
MK="$ROOT/markers"
new_repo "$MK"
printf '{}\n' > "$MK/.myspec.json"
mkdir -p "$MK/.claude/state/isolation"
printf '{"started_at":%d,"feature":"f"}\n' "$((NOW - 120))" > "$MK/.claude/state/implement-in-progress.json"
printf '{"mode":"worktree","worktree_path":"/w/x","decided_at":%d}\n' "$((NOW - 60))" > "$MK/.claude/state/isolation/mk1.json"
printf '{"mode":"develop","worktree_path":"","decided_at":%d}\n' "$((NOW - 60))" > "$MK/.claude/state/isolation/mk-other.json"
session_implement_active "$MK" mk1 && ok || fail "markers: a fresh implement marker is imported as a start"
session_isolation "$MK" mk1
eq "$ISO_MODE|$ISO_PATH" "worktree|/w/x" "markers: the session's isolation marker is imported"
[ ! -e "$MK/.claude/state/implement-in-progress.json" ] && [ -f "$MK/.claude/state/implement-in-progress.json.imported" ] && ok || fail "markers: the implement marker is renamed .imported"
[ -f "$MK/.claude/state/isolation/mk1.json.imported" ] && [ -f "$MK/.claude/state/isolation/mk-other.json" ] && ok || fail "markers: only the session's own isolation marker is taken"
printf '{"started_at":%d,"feature":"f"}\n' "$((NOW - 120))" > "$MK/.claude/state/implement-in-progress.json"
session_events "$MK" mk1 >/dev/null
eq "$(session_events "$MK" mk1 | jq -r 'select(.t == "implement") | .state' | tr '\n' ' ')" "start " "markers: a session imports the implement marker once"
printf '{"started_at":%d,"feature":"f"}\n' "$((NOW - HOOK_DECISION_TTL - 10))" > "$MK/.claude/state/implement-in-progress.json"
session_implement_active "$MK" mk2 && fail "markers: a stale implement marker is not imported" || ok

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
