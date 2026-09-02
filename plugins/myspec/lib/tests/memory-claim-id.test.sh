#!/usr/bin/env bash
# Regression fixture for memory-claim-id.sh.
#
# Every case here is a way the allocator has handed out, or could hand out, a
# number that was already taken. The 2026-09 audit of four real projects found
# the first three in the wild (lowercase names, branch-only memories, no jq);
# the rest guard the lock and the registry, which are what make a claim durable
# before the file exists.
#
# Each case gets a fresh scratch repo, because the registry is a floor that
# only rises: a case run after another in the same repo would be answered by
# the registry, not by the scan it is meant to prove.
#
# Allocation cases run with MYSPEC_SKIP_MEMORY_DOCTOR=1 so they do not depend
# on the doctor; the gate itself is exercised against a fake doctor placed next
# to a copy of the script.
#
# Usage: memory-claim-id.test.sh [path-to-script]

set -uo pipefail

SCRIPT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../memory-claim-id.sh}"

if [ ! -x "$SCRIPT" ]; then
  echo "FATAL: script not executable: $SCRIPT" >&2
  exit 1
fi

ROOT=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

check() {  # check <description> <want> <got>
  if [ "$2" = "$3" ]; then
    pass "$1"
  else
    fail "$1  want=[$2] got=[${3:-<none>}]"
  fi
}

check_contains() {  # check_contains <description> <needle> <haystack>
  case "$3" in
    *"$2"*) pass "$1" ;;
    *) fail "$1  missing [$2] in: $3" ;;
  esac
}

# new_repo <name> [aiDir]  — fresh scratch repo with one commit; cd into it.
new_repo() {
  REPO="$ROOT/$1"
  mkdir -p "$REPO"
  cd "$REPO" || exit 1
  git init -q -b main .
  git config user.email t@t
  git config user.name t
  printf '{\n  "aiDir": "%s",\n  "frameworkVersion": "1.27.0"\n}\n' "${2:-.ai}" > .myspec.json
  mkdir -p .ai/memory/procedural .ai/memory/semantic .ai/memory/episodic
  echo "# index" > .ai/memory/procedural/index.md
  git add -A
  git commit -qm init
}

# mem <type> <basename> [commit message]  — write a memory file; commit if a message is given.
mem() {
  printf -- '---\nid: %s\n---\n# %s\n' "${2%%.*}" "$2" > ".ai/memory/$1/$2"
  if [ -n "${3:-}" ]; then
    git add -A
    git commit -qm "$3"
  fi
}

# claim [type]  — run the allocator with the doctor skipped; stderr lands in $ERR.
ERR="$ROOT/stderr"
claim() {
  MYSPEC_SKIP_MEMORY_DOCTOR=1 "$SCRIPT" "${1:-procedural}" 2>"$ERR"
}

reg() {  # reg <P|S|E>  — value recorded in the registry of the current repo
  sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" .claude/state/memory-ids.json | tail -1
}

json_ok() {  # json_ok <file>  — parse with whatever JSON reader is around
  if command -v node >/dev/null 2>&1; then
    node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$1" 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$1" 2>/dev/null
  elif command -v jq >/dev/null 2>&1; then
    jq -e . "$1" >/dev/null 2>&1
  fi
}

# --- usage / not a repo -----------------------------------------------------

cd "$ROOT" || exit 1
MYSPEC_SKIP_MEMORY_DOCTOR=1 "$SCRIPT" >/dev/null 2>&1
check "usage: no argument exits 2" 2 "$?"
MYSPEC_SKIP_MEMORY_DOCTOR=1 "$SCRIPT" bogus >/dev/null 2>&1
check "usage: unknown type exits 2" 2 "$?"
MYSPEC_SKIP_MEMORY_DOCTOR=1 "$SCRIPT" procedural >/dev/null 2>&1
check "outside a git repository exits 2" 2 "$?"

# --- (a) uppercase files -----------------------------------------------------

new_repo a
mem procedural P001-first.md "P001"
mem procedural P002-second.md "P002"
got=$(claim)
check "(a) P001,P002 on disk -> P003" P003 "$got"
check "(a) registry records 3" 3 "$(reg P)"
check "(a) stderr is empty" "" "$(cat "$ERR")"

# --- (b) lowercase files -----------------------------------------------------

new_repo b
mem procedural p001-x.md "p001"
mem procedural p002-y.md "p002"
got=$(claim)
check "(b) lowercase p001,p002 -> P003, not P001" P003 "$got"

# --- (c) slugless names ------------------------------------------------------

new_repo c
mem procedural P001-first.md "P001"
mem procedural P004.md "P004 slugless"
got=$(claim)
check "(c) slugless P004.md -> P005" P005 "$got"

# --- (d) branch-only and remote-only memories --------------------------------

new_repo d
mem procedural P001-first.md "P001"
git checkout -q -b feat/x
mem procedural P009-branch-only.md "P009 on feat/x"
git checkout -q main
if [ -f .ai/memory/procedural/P009-branch-only.md ]; then
  fail "(d) fixture: P009 should be absent from main"
fi
got=$(claim)
check "(d) P009 committed only on feat/x -> P010" P010 "$got"

git clone -q --bare . "$ROOT/d-origin.git"
git remote add origin "$ROOT/d-origin.git"
git checkout -q -b feat/remote-only main
mem procedural p015-remote-only.md "p015 pushed then deleted locally"
git push -q origin feat/remote-only 2>/dev/null
git checkout -q main
git branch -q -D feat/remote-only
if ! git rev-parse --verify --quiet refs/remotes/origin/feat/remote-only >/dev/null; then
  fail "(d) fixture: remote-tracking ref should survive the local delete"
fi
got=$(claim)
check "(d) p015 only on origin/feat/remote-only -> P016" P016 "$got"

# --- (e) registry ahead of disk, other prefixes preserved --------------------

new_repo e
mem procedural P001-first.md "P001"
mem semantic S001-fact.md "S001"
mem semantic S003-fact.md "S003"
mkdir -p .claude/state
printf '{\n  "P": 20,\n  "S": 5,\n  "E": 7\n}\n' > .claude/state/memory-ids.json
got=$(claim)
check "(e) registry P=20 ahead of disk -> P021" P021 "$got"
check "(e) registry P becomes 21" 21 "$(reg P)"
check "(e) registry S preserved" 5 "$(reg S)"
check "(e) registry E preserved" 7 "$(reg E)"
got=$(claim semantic)
check "(e) semantic claim honours the S floor -> S006" S006 "$got"
check "(e) semantic claim leaves P at 21" 21 "$(reg P)"
got=$(claim episodic)
check "(e) episodic claim with no files -> E008" E008 "$got"
if json_ok .claude/state/memory-ids.json; then
  pass "(e) rewritten registry is valid JSON"
else
  fail "(e) rewritten registry is not valid JSON: $(cat .claude/state/memory-ids.json)"
fi

# --- (f) PATH without jq -----------------------------------------------------

BIN="$ROOT/bin"
mkdir -p "$BIN"
for tool in bash git sed tail dirname mkdir stat date mv rmdir rm sleep find sort awk; do
  src=$(command -v "$tool") || { fail "(f) fixture: $tool not found"; continue; }
  ln -s "$src" "$BIN/$tool"
done
if PATH="$BIN" command -v jq >/dev/null 2>&1; then
  fail "(f) fixture: jq still reachable on the restricted PATH"
fi

new_repo f
mem procedural P005-first.md "P005"
got=$(PATH="$BIN" claim)
check "(f) first claim without jq -> P006" P006 "$got"
got=$(PATH="$BIN" claim)
check "(f) second claim without jq, no file written -> P007" P007 "$got"
check "(f) stderr is empty" "" "$(cat "$ERR")"
if json_ok .claude/state/memory-ids.json; then
  pass "(f) registry written without jq is valid JSON"
else
  fail "(f) registry written without jq is not valid JSON: $(cat .claude/state/memory-ids.json)"
fi

# --- (g) linked worktree with an uncommitted file ----------------------------

new_repo g
mem procedural P001-first.md "P001"
git worktree add -q "$ROOT/g-wt" -b wt-branch
mkdir -p "$ROOT/g-wt/.ai/memory/procedural"
printf -- '---\nid: P030\n---\n' > "$ROOT/g-wt/.ai/memory/procedural/P030-wt.md"
cd "$ROOT/g-wt" || exit 1
got=$(claim)
check "(g) uncommitted P030 in a linked worktree -> P031" P031 "$got"
if [ -f "$REPO/.claude/state/memory-ids.json" ] && [ ! -e "$ROOT/g-wt/.claude/state/memory-ids.json" ]; then
  pass "(g) registry lives in the main checkout, not the worktree"
else
  fail "(g) registry should be in the main checkout only"
fi
cd "$REPO" || exit 1

# --- (h) two concurrent claims -----------------------------------------------

new_repo h
mem procedural P001-first.md "P001"
MYSPEC_SKIP_MEMORY_DOCTOR=1 "$SCRIPT" procedural > "$ROOT/h1.out" 2>/dev/null &
MYSPEC_SKIP_MEMORY_DOCTOR=1 "$SCRIPT" procedural > "$ROOT/h2.out" 2>/dev/null &
wait
h1=$(cat "$ROOT/h1.out")
h2=$(cat "$ROOT/h2.out")
if [ "$h1" != "$h2" ] && [ -n "$h1" ] && [ -n "$h2" ]; then
  pass "(h) concurrent claims are distinct ($h1, $h2)"
else
  fail "(h) concurrent claims collided or failed: [$h1] [$h2]"
fi
sorted=$(printf '%s\n%s\n' "$h1" "$h2" | sort | tr '\n' ' ')
check "(h) concurrent claims are P002 and P003" "P002 P003 " "$sorted"
if [ -e .claude/state/memory-id.lock ]; then
  fail "(h) lock left behind after both claims"
else
  pass "(h) lock released after both claims"
fi

# --- (i) stale and live locks ------------------------------------------------

new_repo i
mkdir -p .claude/state/memory-id.lock
touch -t 202001010000 .claude/state/memory-id.lock
got=$(claim)
rc=$?
check "(i) stale lock (>60s) is broken and the claim succeeds" "0 P001" "$rc $got"
if [ -e .claude/state/memory-id.lock ]; then
  fail "(i) stale lock still present after the claim"
else
  pass "(i) stale lock removed"
fi
stale_left=$(find .claude/state -maxdepth 1 -name 'memory-id.lock.stale.*' | wc -l | tr -d ' ')
check "(i) no stale rename left behind" 0 "$stale_left"

# A live lock held briefly by someone else must be waited on, not broken.
mkdir .claude/state/memory-id.lock
( sleep 0.5; rmdir .claude/state/memory-id.lock ) &
got=$(claim)
rc=$?
wait
check "(i) live lock is waited on, then the claim succeeds" "0 P002" "$rc $got"

# --- (j) conformance gate ----------------------------------------------------

GATE_BIN="$ROOT/gate-bin"
mkdir -p "$GATE_BIN"
cp "$SCRIPT" "$GATE_BIN/memory-claim-id.sh"
chmod +x "$GATE_BIN/memory-claim-id.sh"
cat > "$GATE_BIN/memory-doctor.mjs" <<'EOF'
import { writeFileSync } from 'node:fs';
writeFileSync(process.env.FAKE_DOCTOR_ARGV, process.argv.slice(2).join(' '));
if (process.env.FAKE_DOCTOR_MODE === 'fail') {
  console.log('ERROR duplicate-id: P001 claimed by P001-first.md and p001-dup.md');
  console.log('1 error, 0 warnings');
  process.exit(1);
}
console.log('memory tree conforms');
process.exit(0);
EOF

new_repo j
mem procedural P001-first.md "P001"

if command -v node >/dev/null 2>&1; then
  got=$(FAKE_DOCTOR_MODE=fail FAKE_DOCTOR_ARGV="$ROOT/argv" "$GATE_BIN/memory-claim-id.sh" procedural 2>"$ERR")
  rc=$?
  check "(j) doctor errors -> exit 3" 3 "$rc"
  check "(j) doctor errors -> no ID printed" "" "$got"
  check_contains "(j) doctor output relayed on stderr" "ERROR duplicate-id" "$(cat "$ERR")"
  check_contains "(j) refusal line on stderr" "refusing to allocate" "$(cat "$ERR")"
  if [ -e .claude/state/memory-ids.json ]; then
    fail "(j) refusal must not touch the registry"
  else
    pass "(j) refusal leaves no registry behind"
  fi
  argv=$(cat "$ROOT/argv")
  check_contains "(j) doctor invoked with --quiet" "--quiet" "$argv"
  root_arg=${argv##*--root }
  root_arg=${root_arg%% *}
  check "(j) doctor invoked with --root <main checkout>" "$REPO" "$(cd "$root_arg" 2>/dev/null && pwd -P)"

  got=$(FAKE_DOCTOR_MODE=ok FAKE_DOCTOR_ARGV="$ROOT/argv" "$GATE_BIN/memory-claim-id.sh" procedural 2>"$ERR")
  rc=$?
  check "(j) doctor clean -> claim proceeds" "0 P002" "$rc $got"
  check "(j) doctor clean -> stderr is empty" "" "$(cat "$ERR")"

  got=$(FAKE_DOCTOR_MODE=fail FAKE_DOCTOR_ARGV="$ROOT/argv" MYSPEC_SKIP_MEMORY_DOCTOR=1 "$GATE_BIN/memory-claim-id.sh" procedural 2>"$ERR")
  rc=$?
  check "(j) MYSPEC_SKIP_MEMORY_DOCTOR=1 bypasses a failing doctor" "0 P003" "$rc $got"

  # node absent from PATH: the gate is skipped with a warning, not a refusal.
  got=$(PATH="$BIN" FAKE_DOCTOR_MODE=fail FAKE_DOCTOR_ARGV="$ROOT/argv" "$GATE_BIN/memory-claim-id.sh" procedural 2>"$ERR")
  rc=$?
  check "(j) no node on PATH -> warning and a claim" "0 P004" "$rc $got"
  check_contains "(j) no node on PATH -> skip warning" "conformance check skipped" "$(cat "$ERR")"
else
  echo "SKIP  (j) node not available; gate cases not run" >&2
fi

# Doctor file absent next to the script: warning, then a claim.
NODOC_BIN="$ROOT/nodoc-bin"
mkdir -p "$NODOC_BIN"
cp "$SCRIPT" "$NODOC_BIN/memory-claim-id.sh"
chmod +x "$NODOC_BIN/memory-claim-id.sh"
new_repo j2
mem procedural P001-first.md "P001"
got=$("$NODOC_BIN/memory-claim-id.sh" procedural 2>"$ERR")
rc=$?
check "(j) no memory-doctor.mjs -> warning and a claim" "0 P002" "$rc $got"
check_contains "(j) no memory-doctor.mjs -> skip warning" "conformance check skipped" "$(cat "$ERR")"

# --- (k) aiDir with a trailing slash -----------------------------------------

new_repo k ".ai/"
mem procedural P007-first.md "P007"
got=$(claim)
check "(k) aiDir .ai/ on disk -> P008" P008 "$got"
git checkout -q -b feat/slash
mem procedural P012-branch.md "P012 on feat/slash"
git checkout -q main
got=$(claim)
check "(k) aiDir .ai/ ref scan pathspec -> P013" P013 "$got"

# --- (l) many refs: unique-tip scan stays fast --------------------------------

new_repo l
mem procedural P001-first.md "P001"
i=1
while [ "$i" -le 120 ]; do
  git checkout -q -b "b$i" main
  if [ "$i" -eq 77 ]; then
    mem procedural p050-deep.md "p050 on b77"
  else
    git commit -q --allow-empty -m "b$i"
  fi
  i=$((i + 1))
done
git checkout -q main
refs=$(git for-each-ref refs/heads | wc -l | tr -d ' ')
start=$(date +%s)
got=$(claim)
elapsed=$(( $(date +%s) - start ))
check "(l) p050 on one of $refs refs -> P051" P051 "$got"
if [ "$elapsed" -le 3 ]; then
  pass "(l) $refs refs scanned in ${elapsed}s"
else
  fail "(l) $refs refs took ${elapsed}s (limit 3s)"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
