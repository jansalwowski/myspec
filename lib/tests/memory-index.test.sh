#!/usr/bin/env bash
# Regression fixture for memory-index.mjs.
#
# The generator rewrites a file that agents read on every task, so the cases
# that matter are the ones where a run silently loses text: a legacy index
# whose bare-ID rows were invisible, a lowercase or slugless memory the file
# regex skipped, an anchor form the parser did not read, a hook whose `\|`
# got escaped twice. Each is built here from scratch and run through the
# refusal, the dry run, the backfill, the migration, and two idempotent
# regenerations.
#
# Two refusals are exercised: a memory with neither `hook:` nor a row (P003
# here, no hook source at all), and a legacy index whose memories lack `hook:`
# in their files — the rows are a legitimate hook source, but the header is
# migrated only under --backfill, once those hooks have been written to disk.
#
# Usage: memory-index.test.sh [path-to-script]

set -uo pipefail

SCRIPT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../memory-index.mjs}"

if [ ! -f "$SCRIPT" ]; then
  echo "FATAL: script not found: $SCRIPT" >&2
  exit 1
fi

ROOT=$(cd "$(mktemp -d)" && pwd -P)
REPO="$ROOT/repo"
MEM="$REPO/.ai/memory"
mkdir -p "$MEM/procedural" "$MEM/semantic" "$MEM/episodic"
trap 'rm -rf "$ROOT"' EXIT

cd "$REPO" || exit 1
git init -q .
printf '{ "aiDir": ".ai" }\n' > .myspec.json

PASS=0
FAIL=0

ok() {  # ok <description>
  PASS=$((PASS + 1))
}

fail() {  # fail <description> [detail]
  FAIL=$((FAIL + 1))
  printf 'FAIL  %s\n' "$1" >&2
  [ -n "${2:-}" ] && printf '      %s\n' "$2" >&2
}

run() {  # run <args...>  → OUT (stdout+stderr), CODE
  OUT=$(node "$SCRIPT" "$@" 2>&1)
  CODE=$?
}

expect_code() {  # expect_code <want> <description>
  if [ "$CODE" -eq "$1" ]; then ok; else fail "$2" "exit=$CODE want=$1"; fi
}

expect_out() {  # expect_out <needle> <description>
  case "$OUT" in *"$1"*) ok ;; *) fail "$2" "output lacks: $1" ;; esac
}

expect_no_out() {  # expect_no_out <needle> <description>
  case "$OUT" in *"$1"*) fail "$2" "output has: $1" ;; *) ok ;; esac
}

expect_file() {  # expect_file <file> <fixed-string> <description>
  if grep -qF -- "$2" "$1"; then ok; else fail "$3" "$1 lacks: $2"; fi
}

expect_no_file() {  # expect_no_file <file> <fixed-string> <description>
  if grep -qF -- "$2" "$1"; then fail "$3" "$1 has: $2"; else ok; fi
}

snapshot() {  # snapshot → checksum of every file under .ai
  find "$MEM" -type f | sort | xargs shasum | shasum
}

rewrite() {  # rewrite <file> <sed-expression>  (portable in-place edit)
  sed "$2" "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

# ---------------------------------------------------------------- fixture

cat > "$MEM/procedural/index.md" <<'EOF'
---
type: procedural
updated: 2020-01-01
last_added: P004
---

# Procedural Memory Index

> **Agent**: Scan "Use When" for keyword matches. Check "Not For" before applying. Load full memory file on match.

| ID | Use When | Handles | Not For |
|----|----------|---------|---------|
| P001 | token refresh, use "quoted" text | errorLink conditions | server-side auth |
| P002 | guard `mongoose.models.X \|\| model(...)` | idempotent compile | single-chunk builds |
| P004 | superseded thing | old | new |

Trailing note stays.
EOF

cat > "$MEM/procedural/P001-token-refresh.md" <<'EOF'
---
id: P001
type: procedural
created: 2026-05-01
anchors: [{file: "src/utils/errorLink.js", pattern: "refresh"}]
---

# P001: Token Refresh Conditions

Body.
EOF

cat > "$MEM/procedural/p002-mongoose-guard.md" <<'EOF'
---
id: P002
type: procedural
created: 2026-05-02
anchors:
  - file: "server/models/FeatureFlag.js"
    pattern: "mongoose.models"
---

# P002: Guard the mongoose model

Body.
EOF

cat > "$MEM/procedural/P003.md" <<'EOF'
---
type: procedural
created: 2026-05-03
---

# P003: Slugless memory

Body.
EOF

cat > "$MEM/procedural/P004-old.md" <<'EOF'
---
id: P004
hook: "superseded thing"
type: procedural
status: superseded
created: 2026-05-04
---

# P004: Old

Body.
EOF

cat > "$MEM/semantic/index.md" <<'EOF'
---
type: semantic
updated: 2020-01-01
---

# Semantic Memory Index

> **Agent**: Match "Topic" against current task domain. Check "Anchor" column — if marked ⚠️, verify before relying on this fact.

| ID | Topic | Fact | Verified | Anchor |
|----|-------|------|----------|--------|
| S001 | flow anchors | first fact | 2026-05-01 | — |
| S002 | no anchors | legacy path carried over | 2026-05-02 | `src/legacy.js` |
| S003 | block anchors | third fact | 2026-05-03 | ⚠️ |
| S004 |  | fact only, empty topic | 2026-05-04 | `ErrorLogListenerDecorator` monolith-app |
EOF

cat > "$MEM/semantic/S001-flow.md" <<'EOF'
---
id: S001
type: semantic
anchors: [{file: "config/flow.js", pattern: "FLOW"}, {file: "config/other.js", pattern: "x"}]
---

# S001: Flow anchors
EOF

cat > "$MEM/semantic/S002.md" <<'EOF'
---
id: S002
type: semantic
---

# S002: No anchors
EOF

cat > "$MEM/semantic/S003-block.md" <<'EOF'
---
id: S003
type: semantic
anchors:
  - {file: "server/block.js", pattern: "BLOCK"}
---

# S003: Block anchors
EOF

cat > "$MEM/semantic/S004-map.md" <<'EOF'
---
id: S004
type: semantic
anchor:
  file: "server/map.js"
  pattern: "MAP"
---

# S004: Map anchor
EOF

cat > "$MEM/episodic/index.md" <<'EOF'
---
type: episodic
updated: 2020-01-01
---

# Episodic Memory Index

> **Agent**: Check recent episodes (< 30 days) for context. Episodes marked `persistent` remain indefinitely. Others consolidate into semantic facts after 30 days.

| ID | Date | Event | Feature | Outcome |
|----|------|-------|---------|---------|
| E001 | 2026-07-18 | stage-4 lockout fixed same day | map-mask/import-wizard | success |
| E002 | 2026-07-20 | border-points report to v10 ship |  | success |
EOF

cat > "$MEM/episodic/E001-lockout.md" <<'EOF'
---
id: E001
type: episodic
date: 2026-07-19
---

# Same-day arc: lockout to ship
EOF

cat > "$MEM/episodic/E002.md" <<'EOF'
---
id: E002
type: episodic
---

# Border points to v10
EOF

git add -A
git commit -qm fixture

# ------------------------------------------------- (a) legacy indexes: --check

# P003 has neither hook: nor a row, so procedural is refused outright;
# P001/P002 carry their hook in a legacy row, so they are not "missing".
# Semantic and episodic are legacy indexes whose files lack hook: — refused
# until --backfill writes the row-derived hooks into the files.
run --check
expect_code 1 "--check fails on legacy indexes"
expect_out "missing hook: .ai/memory/procedural/P003.md" "--check names the row-less slugless P003"
expect_no_out "P001-token-refresh.md" "--check does not name P001 — its legacy row is a hook source"
expect_no_out "P004-old.md" "--check does not name the superseded P004"
expect_out "refusing to regenerate .ai/memory/procedural/index.md" "--check says which index is refused"
expect_out "run --backfill" "--check prints the backfill advice"
expect_out "legacy index: 4 memory file(s) lack hook: — run --backfill to write them before migrating the header" "--check refuses the legacy semantic index until backfill"
expect_out "refusing to regenerate .ai/memory/semantic/index.md" "--check names the refused semantic index"
expect_out "legacy index: 2 memory file(s) lack hook: — run --backfill to write them before migrating the header" "--check refuses the legacy episodic index until backfill"
expect_out "refusing to regenerate .ai/memory/episodic/index.md" "--check names the refused episodic index"

# ------------------------------------------------- (a) plain run: nothing migrates without --backfill

BEFORE=$(snapshot)
run --dry-run
expect_code 1 "--dry-run still exits 1 for the refused indexes"
expect_out "refusing to regenerate .ai/memory/semantic/index.md" "--dry-run refuses the legacy semantic index too"
[ "$(snapshot)" = "$BEFORE" ] && ok || fail "--dry-run must not write anything"

run
expect_code 1 "plain run refuses — no silent H1 fallback, no header migration without backfill"
expect_out "rewrote 0 index file(s)" "plain run migrates nothing while files lack hook:"
expect_file "$MEM/procedural/index.md" "| ID | Use When | Handles | Not For |" "refused procedural index is left untouched"
expect_file "$MEM/semantic/index.md" "| ID | Topic | Fact | Verified | Anchor |" "refused semantic index keeps its legacy header"
expect_no_file "$MEM/semantic/S002.md" "hook:" "plain run does not write hook: into files"

# ------------------------------------------------- (a) backfill dry run

BEFORE=$(snapshot)
run --backfill --dry-run
expect_code 0 "--backfill --dry-run exits 0 once every hook can be derived"
expect_out "would backfill from heading (review): .ai/memory/procedural/P003.md" "dry run flags the heading-derived hook"
expect_out ".ai/memory/procedural/index.md: would backfill hook: 3 file(s) [1 from heading]" "dry run counts procedural backfills"
expect_out ".ai/memory/semantic/index.md: would backfill hook: 4 file(s) [0 from heading]" "dry run counts semantic backfills from the migrated rows"
expect_out ".ai/memory/episodic/index.md: would backfill hook: 2 file(s) [0 from heading]" "dry run counts episodic backfills"
expect_out ".ai/memory/procedural/index.md: would migrate header (legacy → canonical)" "dry run announces the procedural migration"
expect_out ".ai/memory/procedural/index.md: rows: +1 -1 ~2" "dry run reports P003 added, P004 removed, two rows relinked"
expect_out ".ai/memory/semantic/index.md: would migrate header (legacy → canonical)" "dry run announces the semantic migration once hooks can be backfilled"
expect_out ".ai/memory/semantic/index.md: rows: +0 -0 ~4" "dry run: every semantic row is relinked, none added or removed"
expect_out "nothing written" "dry run says it wrote nothing"
[ "$(snapshot)" = "$BEFORE" ] && ok || fail "--backfill --dry-run must not write anything"

# ------------------------------------------------- (a) backfill for real

run --backfill
expect_code 0 "--backfill succeeds"
expect_out "backfilled from heading (review): .ai/memory/procedural/P003.md" "backfill flags the heading-derived hook"
expect_out ".ai/memory/procedural/index.md: backfilled hook: 3 file(s) [1 from heading]" "backfill reports the procedural count"
expect_out "rewrote 3 index file(s)" "backfill migrates all three legacy indexes"
expect_file "$MEM/semantic/index.md" "| ID | Hook | Anchor |" "semantic header migrated under backfill"

expect_file "$MEM/procedural/P001-token-refresh.md" 'hook: "token refresh, use \"quoted\" text"' "P001 hook from Use When, quotes escaped for YAML"
expect_file "$MEM/procedural/p002-mongoose-guard.md" 'hook: "guard `mongoose.models.X || model(...)`"' "p002 hook has the cell escaping undone"
expect_file "$MEM/semantic/S001-flow.md" 'hook: "flow anchors — first fact"' "S001 hook is Topic — Fact"
expect_file "$MEM/semantic/S004-map.md" 'hook: "fact only, empty topic"' "S004 hook skips the joiner when Topic is empty"
expect_file "$MEM/episodic/E001-lockout.md" 'hook: "stage-4 lockout fixed same day (map-mask/import-wizard)"' "E001 hook is Event (Feature)"
expect_file "$MEM/episodic/E002.md" 'hook: "border-points report to v10 ship"' "E002 hook has no parens when Feature is empty"

if [ "$(sed -n '2p' "$MEM/procedural/P001-token-refresh.md")" = "id: P001" ] && [ "$(sed -n '3p' "$MEM/procedural/P001-token-refresh.md")" = 'hook: "token refresh, use \"quoted\" text"' ]; then
  ok
else
  fail "hook: is inserted directly after id:"
fi

if [ "$(sed -n '2p' "$MEM/procedural/P003.md")" = 'hook: "P003: Slugless memory"' ]; then
  ok
else
  fail "hook: is the first frontmatter line when there is no id:"
fi

# ------------------------------------------------- (a) migrated header + note

IDX="$MEM/procedural/index.md"
expect_file "$IDX" "| ID | Hook | Anchor |" "procedural header is canonical"
expect_file "$IDX" "|----|------|--------|" "procedural separator is canonical"
expect_no_file "$IDX" "Use When" "legacy header is gone"
expect_file "$IDX" '> **Agent**: Scan "Hook" for keyword matches against the task or error.' "procedural agent note replaced"
expect_no_file "$IDX" 'Scan "Use When"' "old procedural note removed"
expect_file "$IDX" "Trailing note stays." "prose after the table preserved"
expect_file "$IDX" "last_added: P004" "frontmatter outside updated: preserved"
expect_file "$IDX" "updated: $(date +%Y-%m-%d)" "updated: bumped when the table changed"
[ "$(grep -c '^| \[P' "$IDX")" -eq 3 ] && ok || fail "procedural row count preserved (3 live rows)" "$(grep '^| \[P' "$IDX")"

expect_file "$MEM/semantic/index.md" '> **Agent**: Scan "Hook" for topic matches.' "semantic agent note replaced"
expect_file "$MEM/episodic/index.md" "| ID | Hook | Date |" "episodic header is canonical"
expect_file "$MEM/episodic/index.md" '> **Agent**: Scan "Hook" for events related to the current feature.' "episodic agent note replaced"

# ------------------------------------------------- (b) lowercase + slugless rows

expect_file "$IDX" '| [P001](P001-token-refresh.md) | token refresh, use "quoted" text | src/utils/errorLink.js |' "P001 row: linked, flow anchor"
expect_file "$IDX" '| [P002](p002-mongoose-guard.md) | guard `mongoose.models.X \|\| model(...)` | server/models/FeatureFlag.js |' "p002 row: uppercase ID, lowercase target, block-map anchor, single escaping"
expect_file "$IDX" '| [P003](P003.md) | P003: Slugless memory | --- |' "P003 row: slugless target, heading hook, no anchor"

# ------------------------------------------------- (c) anchor forms

SIDX="$MEM/semantic/index.md"
expect_file "$SIDX" '| [S001](S001-flow.md) | flow anchors — first fact | config/flow.js |' "flow-list anchor fills the column (first file)"
expect_file "$SIDX" '| [S002](S002.md) | no anchors — legacy path carried over | src/legacy.js |' "legacy path-like Anchor cell carried over, backticks dropped"
expect_file "$SIDX" '| [S003](S003-block.md) | block anchors — third fact | server/block.js |' "block-list anchor fills the column; legacy warning sign dropped"
expect_file "$SIDX" '| [S004](S004-map.md) | fact only, empty topic | server/map.js |' "anchor: map form fills the column; non-path legacy cell ignored"

# ------------------------------------------------- (d) superseded excluded

expect_no_file "$IDX" "[P004]" "superseded P004 has no row"

# ------------------------------------------------- (h) episodic Date column

EIDX="$MEM/episodic/index.md"
expect_file "$EIDX" '| [E001](E001-lockout.md) | stage-4 lockout fixed same day (map-mask/import-wizard) | 2026-07-19 |' "E001 Date comes from date: frontmatter, not the legacy cell"
expect_file "$EIDX" '| [E002](E002.md) | border-points report to v10 ship | 2026-07-20 |' "E002 Date falls back to the legacy cell"

# ------------------------------------------------- (f) idempotent

run --check
expect_code 0 "--check passes right after the migration"
expect_out "memory indexes are up to date" "--check reports clean"

AFTER_FIRST=$(snapshot)
run
expect_code 0 "second plain run succeeds"
expect_out "rewrote 0 index file(s)" "second plain run rewrites nothing"
[ "$(snapshot)" = "$AFTER_FIRST" ] && ok || fail "second plain run changes no file"

run --dry-run
expect_out ".ai/memory/procedural/index.md: up to date" "dry run reports up to date"

# updated: only moves with the table — a no-op run leaves an old date alone.
rewrite "$IDX" 's/^updated: .*/updated: 2020-01-01/'
run
expect_file "$IDX" "updated: 2020-01-01" "updated: untouched when the table did not change"

# ------------------------------------------------- (g) \| survives regenerations

run
run
expect_file "$IDX" 'guard `mongoose.models.X \|\| model(...)`' "escaped pipes intact after two more regenerations"
expect_no_file "$IDX" '\\|' "pipes never double-escaped"

# ------------------------------------------------- new-format row edits and dry-run row diff

cat > "$MEM/procedural/P005-new.md" <<'EOF'
---
id: P005
hook: "a brand new memory"
type: procedural
---

# P005: New
EOF

run --dry-run
expect_code 0 "dry run with a new memory exits 0"
expect_out ".ai/memory/procedural/index.md: rows: +1 -0 ~0" "dry run reports the added row"
expect_no_file "$IDX" "P005" "dry run did not write the new row"

run
expect_file "$IDX" '| [P005](P005-new.md) | a brand new memory | --- |' "plain run adds the new row"
expect_file "$IDX" "updated: $(date +%Y-%m-%d)" "updated: bumped again when a row is added"

# A hook: without a row and without --backfill still refuses; a missing hook on
# a memory that HAS a generated row is fine (the row is the second source).
rewrite "$MEM/procedural/P005-new.md" '/^hook:/d'
run --check
expect_code 0 "existing generated row supplies the hook when hook: is removed"

cat > "$MEM/procedural/P006-nohook.md" <<'EOF'
---
id: P006
type: procedural
---

# P006: Heading only
EOF

run --check
expect_code 1 "--check refuses a new memory with neither hook: nor row"
expect_out "missing hook: .ai/memory/procedural/P006-nohook.md" "--check names the hookless newcomer"

run --backfill
expect_out "backfilled from heading (review): .ai/memory/procedural/P006-nohook.md" "backfill flags a heading-derived hook for review"
expect_out "backfilled hook: 2 file(s) [1 from heading]" "backfill counts the row-derived and heading-derived hooks"
expect_file "$MEM/procedural/P006-nohook.md" 'hook: "P006: Heading only"' "heading-derived hook written"
expect_file "$MEM/procedural/P005-new.md" 'hook: "a brand new memory"' "row-derived hook written back for P005"

# ------------------------------------------------- (e) duplicate IDs

cat > "$MEM/procedural/p003-b.md" <<'EOF'
---
id: P003
hook: "duplicate of P003"
type: procedural
---

# P003 duplicate
EOF

run --check
expect_code 1 "--check fails on two files resolving to P003"
expect_out "duplicate id P003: .ai/memory/procedural/P003.md, .ai/memory/procedural/p003-b.md" "--check names both duplicate paths"

run
expect_code 1 "plain run refuses the index with duplicate IDs"
expect_no_file "$IDX" "p003-b.md" "duplicate did not reach the table"

rm "$MEM/procedural/p003-b.md"
run --check
expect_code 0 "--check clean again once the duplicate is removed"

# ------------------------------------------------- flags

run --bogus
expect_code 2 "unknown flag exits 2"

run --check --backfill
expect_out "--backfill ignored under --check" "--check --backfill warns and does not write"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
