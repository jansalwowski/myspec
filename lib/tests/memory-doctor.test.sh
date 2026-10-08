#!/usr/bin/env bash
# Regression fixture for memory-doctor.mjs.
#
# The doctor exists because drift was invisible: every check it makes is one
# that a real project silently failed. A fixture is the only way to prove each
# check fires on the shape it was written for and stays quiet on the shapes it
# must tolerate — the tombstone pair above all, since flagging that would
# make the documented supersede pattern look like an error.
#
# Builds a scratch repo with: a branch that keeps a memory file the mainline
# renamed away (a tombstone, not a duplicate), a linked worktree holding an
# uncommitted memory file (duplicate visible only on disk), and one instance
# of every other condition. Two passes: a clean tree first, then the drift.
# A second repo reproduces issue #124: collisions only on stale refs warn.
#
# Usage: memory-doctor.test.sh [path-to-script]

set -uo pipefail

SCRIPT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../memory-doctor.mjs}"

if [ ! -f "$SCRIPT" ]; then
  echo "FATAL: script not found: $SCRIPT" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "FATAL: jq is required" >&2
  exit 1
fi

ROOT=$(cd "$(mktemp -d)" && pwd -P)
REPO="$ROOT/repo"
mkdir -p "$REPO"
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

# expect_line <regex> <description> — OUTPUT must contain a matching line
expect_line() {
  if printf '%s\n' "$OUTPUT" | grep -Eq -- "$1"; then ok; else fail "$2 (no line matching: $1)"; fi
}

# expect_no_line <regex> <description>
expect_no_line() {
  if printf '%s\n' "$OUTPUT" | grep -Eq -- "$1"; then fail "$2 (unexpected line matching: $1)"; else ok; fi
}

expect_exit() {  # expect_exit <want> <description>
  if [ "$STATUS" -eq "$1" ]; then ok; else fail "$2 (exit $STATUS, want $1)"; fi
}

run_doctor() {  # run_doctor <args...>; sets OUTPUT and STATUS
  OUTPUT=$(node "$SCRIPT" "$@" 2>/dev/null)
  STATUS=$?
}

# memory <path> <id> <hook-or-empty> [extra frontmatter lines...]
memory() {
  local path="$1" id="$2" hook="$3"
  shift 3
  {
    echo '---'
    echo "id: $id"
    [ -n "$hook" ] && echo "hook: \"$hook\""
    echo "created: 2026-01-01"
    for line in "$@"; do echo "$line"; done
    echo '---'
    echo
    echo "# $id"
  } > "$path"
}

index() {  # index <path> <header> <rows...>
  local path="$1" header="$2"
  shift 2
  {
    echo '# Index'
    echo
    echo "$header"
    echo "$header" | sed -E 's/[^|]+/---/g'
    for row in "$@"; do echo "$row"; done
  } > "$path"
}

cd "$REPO" || exit 1
git init -q -b main .
git config user.email t@t
git config user.name t

# --- 0. no memory tree at all ------------------------------------------------

printf '{ "aiDir": ".ai/" }\n' > .myspec.json
run_doctor --root "$REPO"
expect_exit 0 "no memory tree exits 0"
expect_line '^memory doctor: no memory tree at \.ai/memory$' "no memory tree is reported"

# --- 1. a clean project -------------------------------------------------------

mkdir -p .ai/memory/procedural .ai/memory/semantic .ai/memory/episodic .claude/state
printf '.claude/state/\n' > .gitignore
# Live anchors: the files exist and contain their patterns.
mkdir -p src
printf 'function foo() {}\n' > src/a.js
printf 'const bar = 1;\n' > src/b.js

memory .ai/memory/procedural/P001-first.md P001 "first thing" 'anchors: [{file: "src/a.js", pattern: "foo"}]' 'related: [S001]'
memory .ai/memory/procedural/P002-old.md P002 "second thing"
memory .ai/memory/semantic/S001-main.md S001 "a fact" 'anchor:' '  file: "src/b.js"' '  pattern: "bar"'
memory .ai/memory/episodic/E001-a.md E001 "an event"
index .ai/memory/procedural/index.md '| ID | Hook | Anchor |' \
  '| [P001](P001-first.md) | first thing | src/a.js |' \
  '| [P002](P002-old.md) | second thing | |'
index .ai/memory/semantic/index.md '| ID | Hook | Anchor |' \
  '| [S001](S001-main.md) | a fact | src/b.js |'
index .ai/memory/episodic/index.md '| ID | Hook | Date |' \
  '| [E001](E001-a.md) | an event | 2026-01-01 |'
git add -A
git commit -qm "clean memory tree"

run_doctor --root "$REPO"
expect_exit 0 "clean project exits 0"
expect_line '^memory doctor: clean$' "clean project reports clean"

# --- 2. drift -----------------------------------------------------------------

# A branch keeps P002-old.md; the mainline renames it. Merging the branch
# deletes the old name, so it is a tombstone, not a duplicate (issue #124).
git branch feat/keeps-old
git mv .ai/memory/procedural/P002-old.md .ai/memory/procedural/P002-new.md
index .ai/memory/procedural/index.md '| ID | Hook | Anchor |' \
  '| [P001](P001-first.md) | first thing | src/a.js |' \
  '| [P002](P002-new.md) | second thing | |'
git add -A
git commit -qm "rename P002"

# A branch-only file whose only other copy is a superseded tombstone must not
# count: E002-a.md on disk is superseded, E002-b.md lives on a branch.
git checkout -q -b feat/e002
memory .ai/memory/episodic/E002-b.md E002 "replacement"
git add -A
git commit -qm "E002 on a branch"
git checkout -q main
memory .ai/memory/episodic/E002-a.md E002 "original" 'status: superseded'

# A linked worktree with an UNCOMMITTED second S001.
git worktree add -q "$ROOT/wt-side" -b feat/side main
memory "$ROOT/wt-side/.ai/memory/semantic/S001-side.md" S001 "side fact"

# Tombstone pair on disk: must not be flagged.
memory .ai/memory/episodic/E001-b.md E001 "an event, rewritten"
# (E001-a.md gains status: superseded)
memory .ai/memory/episodic/E001-a.md E001 "an event" 'status: superseded'

# Episodic index beside a hookless, unindexed memory (an error on both counts).
memory .ai/memory/episodic/E003-nohook.md E003 ""
index .ai/memory/episodic/index.md '| ID | Hook | Date |' \
  '| E001 | an event | 2026-01-01 |'

# Procedural index with every file-level condition.
memory .ai/memory/procedural/P003-nohook.md P003 ""
memory .ai/memory/procedural/P004-empty.md P004 "empty anchors" 'anchors: []'
memory .ai/memory/procedural/p005-lower.md P005 "lowercase name"
memory .ai/memory/procedural/P006.md P006 "slugless"
memory .ai/memory/procedural/P007-mismatch.md P070 "id disagrees"
memory .ai/memory/procedural/P008-related.md P008 "dangling related" 'related: [P099, E001]'
# Dead anchors (#184): a file that is gone, a pattern its file no longer has.
memory .ai/memory/procedural/P010-gone-file.md P010 "gone file" 'anchors: [{file: "src/deleted.js", pattern: "foo"}]'
memory .ai/memory/procedural/P011-gone-pattern.md P011 "gone pattern" 'anchors: [{file: "src/a.js", pattern: "renamedAway"}]'
# A regex pattern that matches is live.
memory .ai/memory/procedural/P012-regex.md P012 "regex pattern" 'anchors: [{file: "src/a.js", pattern: "function fo+\\("}]'
index .ai/memory/procedural/index.md '| ID | Hook | Anchor |' \
  '| [P001](P001-first.md) | first thing | src/a.js |' \
  '| [P002](P002-new.md) | second thing | |' \
  '| [P004](P004-empty.md) | empty anchors | |' \
  '| P005 | lowercase name | |' \
  '| [P006](P006.md) | slugless | |' \
  '| [P007](P007-mismatch.md) | id disagrees | |' \
  '| [P008](P008-old-name.md) | dangling related | |' \
  '| [P009](P009-gone.md) | no such file | |' \
  '| [P010](P010-gone-file.md) | gone file | src/deleted.js |' \
  '| [P011](P011-gone-pattern.md) | gone pattern | src/a.js |' \
  '| [P012](P012-regex.md) | regex pattern | src/a.js |'

# Semantic: malformed and pattern-less anchors.
memory .ai/memory/semantic/S002-bad.md S002 "bad anchor" 'anchor: false'
memory .ai/memory/semantic/S003-scalar.md S003 "scalar anchor" 'anchor: src/c.js'
index .ai/memory/semantic/index.md '| ID | Hook | Anchor |' \
  '| [S001](S001-main.md) | a fact | src/b.js |' \
  '| [S002](S002-bad.md) | bad anchor | |' \
  '| [S003](S003-scalar.md) | scalar anchor | src/c.js |'

# Project-level drift.
: > .gitignore
mkdir -p ai/memory/procedural .claude/rules
printf -- '---\nload_when: always\n---\n# rule\n' > .claude/rules/inert.md
printf -- '---\npaths: ["src/**"]\n---\n# rule\n' > .claude/rules/fine.md

run_doctor --root "$REPO"

if [ -n "${DEBUG_DOCTOR:-}" ]; then
  printf '%s\n' "$OUTPUT" >&2
fi

expect_exit 1 "drifted project exits 1"

# errors
expect_no_line 'duplicate-id: P002' "a file renamed away on the default branch is a tombstone"
expect_line '^ERROR duplicate-id: S001: \.ai/memory/semantic/S001-main\.md, \.ai/memory/semantic/S001-side\.md \(worktree wt-side\)$' "uncommitted worktree duplicate names the worktree"
expect_no_line '^ERROR duplicate-id: E001' "on-disk tombstone pair is not a duplicate"
expect_no_line '^ERROR duplicate-id: E002' "superseded tombstone + branch-only file is not a duplicate"
expect_line '^ERROR missing-hook: \.ai/memory/procedural/P003-nohook\.md' "missing hook under the procedural index is an error"
expect_line '^ERROR missing-hook: \.ai/memory/episodic/E003-nohook\.md' "missing hook under the episodic index is an error"
expect_line '^ERROR index-drift: \.ai/memory/procedural/index\.md: P003 on disk but not in the table' "file missing from the table"
expect_line '^ERROR index-drift: \.ai/memory/procedural/index\.md: P009 in the table but no file' "row without a file"
expect_line '^ERROR index-drift: \.ai/memory/procedural/index\.md: P008 links to P008-old-name\.md, which does not exist' "linked row with a dead target"
expect_no_line '^ERROR index-drift: \.ai/memory/procedural/index\.md: P005' "bare-ID row still counts as indexed"
expect_line '^ERROR index-drift: \.ai/memory/episodic/index\.md: E003 on disk but not in the table' "the episodic index is checked for drift like any other"
expect_line '^ERROR malformed-anchor: \.ai/memory/semantic/S002-bad\.md: anchor value "false"' "anchor: false"

# warnings
expect_line '^WARN anchor-no-pattern: \.ai/memory/semantic/S003-scalar\.md: anchor src/c\.js has no pattern' "scalar anchor has no pattern"
expect_line '^WARN anchor-missing-file: \.ai/memory/procedural/P010-gone-file\.md: anchor src/deleted\.js does not exist' "anchor to a missing file warns"
expect_line '^WARN anchor-pattern-gone: \.ai/memory/procedural/P011-gone-pattern\.md: anchor pattern "renamedAway" no longer matches src/a\.js' "anchor whose pattern is gone warns"
expect_no_line 'anchor-(missing-file|pattern-gone): \.ai/memory/procedural/P012-regex\.md' "a regex pattern that matches is live"
expect_no_line '^ERROR anchor-' "dead anchors are never errors"
expect_line '^WARN empty-anchors: \.ai/memory/procedural/P004-empty\.md: .*remove the key or add one$' "anchors: []"
expect_line '^WARN filename-case: \.ai/memory/procedural/p005-lower\.md: .*rename to P005-lower\.md for consistency$' "lowercase prefix"
expect_line '^WARN filename-slugless: \.ai/memory/procedural/P006\.md' "slugless filename"
expect_line '^WARN id-mismatch: \.ai/memory/procedural/P007-mismatch\.md: id: P070 but the filename says P007$' "id: disagrees with the filename"
expect_line '^WARN dangling-related: \.ai/memory/procedural/P008-related\.md: related P099 has no file$' "dangling related"
expect_no_line '^WARN dangling-related: .*related E001' "related to a superseded file still resolves"
expect_line '^WARN state-not-ignored: \.claude/state/' ".claude/state/ not gitignored"
expect_line '^WARN second-ai-tree: ai/memory exists beside \.ai/memory' "stray second ai tree"
expect_line '^WARN inert-rule-key: \.claude/rules/inert\.md: load_when:' "load_when in a rule"
expect_no_line '^WARN inert-rule-key: \.claude/rules/fine\.md' "paths: rule is fine"

# ordering and summary
FIRST_WARN=$(printf '%s\n' "$OUTPUT" | grep -n '^WARN' | head -1 | cut -d: -f1)
LAST_ERROR=$(printf '%s\n' "$OUTPUT" | grep -n '^ERROR' | tail -1 | cut -d: -f1)
if [ "$LAST_ERROR" -lt "$FIRST_WARN" ]; then ok; else fail "errors are listed before warnings"; fi
N_ERR=$(printf '%s\n' "$OUTPUT" | grep -c '^ERROR')
N_WARN=$(printf '%s\n' "$OUTPUT" | grep -c '^WARN')
expect_line "^memory doctor: $N_ERR error\(s\), $N_WARN warning\(s\)$" "summary counts match the lines"
if [ "$(printf '%s\n' "$OUTPUT" | tail -1)" = "memory doctor: $N_ERR error(s), $N_WARN warning(s)" ]; then ok; else fail "summary is the last line"; fi

# --quiet: errors and summary only
run_doctor --root "$REPO" --quiet
expect_exit 1 "--quiet keeps the exit code"
expect_no_line '^WARN' "--quiet hides warnings"
expect_line '^ERROR duplicate-id: S001' "--quiet keeps errors"
expect_line "^memory doctor: $N_ERR error\(s\), $N_WARN warning\(s\)$" "--quiet keeps the full summary"

# --json: { errors: [...], warnings: [...] } of { id, detail, path }
run_doctor --root "$REPO" --json
expect_exit 1 "--json keeps the exit code"
if printf '%s' "$OUTPUT" | jq -e '.errors | type == "array"' >/dev/null 2>&1; then ok; else fail "--json has an errors array"; fi
if printf '%s' "$OUTPUT" | jq -e '.warnings | type == "array"' >/dev/null 2>&1; then ok; else fail "--json has a warnings array"; fi
if [ "$(printf '%s' "$OUTPUT" | jq '.errors | length')" -eq "$N_ERR" ]; then ok; else fail "--json error count matches text output"; fi
if [ "$(printf '%s' "$OUTPUT" | jq '.warnings | length')" -eq "$N_WARN" ]; then ok; else fail "--json warning count matches text output"; fi
if printf '%s' "$OUTPUT" | jq -e '[.errors[], .warnings[]] | all(has("id") and has("detail") and has("path"))' >/dev/null 2>&1; then ok; else fail "--json findings carry id, detail, path"; fi
if [ "$(printf '%s' "$OUTPUT" | jq -r '.errors[] | select(.id == "duplicate-id" and (.detail | startswith("S001"))) | .path')" = ".ai/memory/semantic/S001-main.md" ]; then ok; else fail "--json duplicate path is the on-disk file"; fi
if [ "$(printf '%s' "$OUTPUT" | jq -r '.warnings[] | select(.id == "state-not-ignored") | .path')" = ".claude/state/" ]; then ok; else fail "--json project-level finding carries a path"; fi

# --- 4. issue #124: an ID deleted on the default branch and reused there -----
#
# Branch A adds S001-x.md, merges into develop, and is reverted there; develop
# then reuses S001 as S001-y.md. feat/a, and stale-b (cut before the revert and
# since diverged), still carry S001-x.md on the remote. A file deleted on the
# default branch is a tombstone, so neither is a duplicate. Two unmerged
# branches that both took P001, and one that took the ID develop holds, are
# collisions only on stale refs: warnings, which the stop hook does not block on.

R2="$ROOT/r2"
git init -q --bare "$ROOT/r2-origin.git"
git init -q -b develop "$R2"
cd "$R2" || exit 1
git config user.email t@t
git config user.name t
git remote add origin "$ROOT/r2-origin.git"
printf '{ "aiDir": ".ai/" }\n' > .myspec.json
printf '.claude/state/\n' > .gitignore
mkdir -p .ai/memory/semantic .ai/memory/procedural
index .ai/memory/semantic/index.md '| ID | Hook | Anchor |'
index .ai/memory/procedural/index.md '| ID | Hook | Anchor |'
git add -A && git commit -qm base

git checkout -q -b feat/a
memory .ai/memory/semantic/S001-x.md S001 "x fact"
index .ai/memory/semantic/index.md '| ID | Hook | Anchor |' '| [S001](S001-x.md) | x fact | |'
git add -A && git commit -qm "S001-x"
git checkout -q develop
git merge -q --no-ff -m "merge a" feat/a
git checkout -q -b stale-b
printf 'x\n' > unrelated.txt
git add -A && git commit -qm "stale-b diverges"
git checkout -q develop
git revert --no-edit -m 1 HEAD >/dev/null
memory .ai/memory/semantic/S001-y.md S001 "y fact"
index .ai/memory/semantic/index.md '| ID | Hook | Anchor |' '| [S001](S001-y.md) | y fact | |'
git add -A && git commit -qm "S001-y reuses the ID"

git checkout -q -b feat/c
memory .ai/memory/procedural/P001-c.md P001 "c"
git add -A && git commit -qm "P001-c"
git checkout -q develop
git checkout -q -b feat/d
memory .ai/memory/procedural/P001-d.md P001 "d"
git add -A && git commit -qm "P001-d"
git checkout -q develop
git checkout -q -b feat/e
memory .ai/memory/semantic/S001-e.md S001 "e"
git add -A && git commit -qm "S001-e"
git checkout -q develop

git push -q origin develop feat/a stale-b feat/c feat/d feat/e 2>/dev/null
git remote set-head origin develop >/dev/null
git fetch -q origin

run_doctor --root "$R2"
[ -n "${DEBUG_DOCTOR:-}" ] && printf '%s\n' "$OUTPUT" >&2
expect_exit 0 "issue #124: stale-ref collisions do not make the doctor fail"
expect_no_line '^ERROR duplicate-id' "issue #124: no duplicate-id error"
expect_no_line 'S001-x\.md' "issue #124: a file deleted on the default branch is a tombstone"
expect_line '^WARN duplicate-id: P001: \.ai/memory/procedural/P001-c\.md \(feat/c, origin/feat/c\), \.ai/memory/procedural/P001-d\.md \(feat/d, origin/feat/d\)' "collision between two stale branches is a warning"
expect_line '^WARN duplicate-id: S001: \.ai/memory/semantic/S001-y\.md, \.ai/memory/semantic/S001-e\.md \(feat/e, origin/feat/e\) — only on stale branches' "stale branch vs the default branch is a warning"

# The same collision is an error once it reaches the default branch tip.
git merge -q -m "land c" feat/c
git merge -q -m "land d" feat/d
run_doctor --root "$R2"
expect_exit 1 "a collision at the default branch tip still fails"
expect_line '^ERROR duplicate-id: P001: \.ai/memory/procedural/P001-c\.md, \.ai/memory/procedural/P001-d\.md$' "collision at the default branch tip is an error"

# --- 5. issue #341: an anchor pattern is an ERE matched line by line ---------
#
# memory-anchor.mjs is the one definition (its header lists the rules); the
# doctor and the skills both run it. One memory per rule, each named for it.

R3="$ROOT/r3"
mkdir -p "$R3/.ai/memory/procedural" "$R3/src"
cd "$R3" || exit 1
git init -q -b main .
printf '{ "aiDir": ".ai/" }\n' > .myspec.json
printf '.claude/state/\n' > .gitignore
printf '# build targets\n\ninstall:\n\tnpm ci\ncomposer:\n\tcomposer install\n' > Makefile
printf 'install:\r\ncomposer:\r\n' > crlf.mk
# shellcheck disable=SC2016 # literal PHP source, nothing to expand
printf '<?php\n$this->load($name);\n$total = a[0] + 1;\n' > src/Loader.php

anchor() {  # anchor <slug> <file> <yaml-quoted pattern>
  memory ".ai/memory/procedural/P$((++N))-$1.md" "P$N" "$1" "anchors: [{file: \"$2\", pattern: $3}]"
}
N=100
anchor caret-not-line-one Makefile '"^composer:"'
anchor dollar-end-of-line Makefile '"^install:$"'
anchor crlf-dollar crlf.mk '"^install:$"'
anchor dot-star-across-lines Makefile '"install.*composer"'
anchor negated-class-across-lines Makefile '"install:[^x]*composer"'
anchor ere-alternation Makefile '"deploy|install"'
anchor bre-alternation-is-literal Makefile "'deploy\\|install'"
anchor posix-class Makefile "'^[[:alpha:]]+:\$'"
anchor word-boundary Makefile "'\\<composer\\>'"
anchor leading-bracket Makefile "'^[]#]'"
anchor case-sensitive Makefile '"^Composer:"'
anchor literal-invalid-regex src/Loader.php "'\$this->load('"
anchor literal-valid-regex src/Loader.php '"a[0] + 1"'
anchor invalid-regex-absent src/Loader.php "'missing('"
anchor empty-pattern Makefile '""'

run_doctor --root "$R3"
[ -n "${DEBUG_DOCTOR:-}" ] && printf '%s\n' "$OUTPUT" >&2

live() {  # live <slug> <description>
  expect_no_line "^WARN anchor-[a-z-]+: \.ai/memory/procedural/P[0-9]+-$1\.md" "$2"
}
gone() {  # gone <slug> <description>
  expect_line "^WARN anchor-pattern-gone: \.ai/memory/procedural/P[0-9]+-$1\.md" "$2"
}
live caret-not-line-one "#341: ^ anchors to a line start, not the file start"
live dollar-end-of-line "\$ anchors to a line end"
live crlf-dollar "\$ matches before a CRLF line ending"
gone dot-star-across-lines ".* does not cross a line break"
gone negated-class-across-lines "[^x] does not cross a line break"
live ere-alternation "| is alternation (ERE)"
gone bre-alternation-is-literal "\\| is a literal bar, as under grep -E"
live posix-class "[[:alpha:]] is a POSIX class"
live word-boundary "\\< and \\> are word boundaries"
live leading-bracket "a ] opening a bracket is literal"
gone case-sensitive "matching is case-sensitive"
live literal-invalid-regex "a pattern that is not a regex is found literally"
live literal-valid-regex "a regex pattern meant literally is found literally"
expect_line '^WARN anchor-pattern-invalid: \.ai/memory/procedural/P[0-9]+-invalid-regex-absent\.md: anchor pattern "missing\(" is not a valid extended regex' "an invalid regex that is absent says so"
expect_no_line 'anchor-pattern-gone: \.ai/memory/procedural/P[0-9]+-invalid-regex-absent\.md' "an invalid regex is not reported as gone"
expect_line '^WARN anchor-no-pattern: \.ai/memory/procedural/P[0-9]+-empty-pattern\.md' "an empty pattern is no anchor"
expect_no_line 'anchor-pattern-(gone|invalid): \.ai/memory/procedural/P[0-9]+-empty-pattern\.md' "an empty pattern is not tested"

# The command the skills run: same answer, as an exit status.
ANCHOR="$(dirname "$SCRIPT")/memory-anchor.mjs"
cli() {  # cli <want-exit> <description> <args...>
  local want="$1" desc="$2"
  shift 2
  node "$ANCHOR" "$@" >/dev/null 2>&1
  local got=$?
  if [ "$got" -eq "$want" ]; then ok; else fail "memory-anchor.mjs: $desc (exit $got, want $want)"; fi
}
cli 0 "live anchor exits 0" Makefile '^composer:'
cli 1 "cross-line pattern exits 1" Makefile 'install.*composer'
cli 1 "missing file exits 1" nope.mk '^composer:'
cli 1 "invalid regex absent exits 1" src/Loader.php 'missing('
cli 2 "empty pattern is a usage error" Makefile ''
cli 2 "missing pattern is a usage error" Makefile

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
