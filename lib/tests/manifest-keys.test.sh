#!/usr/bin/env bash
# Tests for lib/manifest-keys.mjs (#473): the one place a frameworkFiles key
# resolves to its destination, and the `renames` table update's rename step
# reads. A renamedFrom is a frameworkFiles key, so it may name the other
# block; resolving it in the entry's own block sent a rule moved to the aiDir
# to ${aiDir}/rules/x.md, and a rule renamed to a rule to nothing.
#
# Usage: manifest-keys.test.sh [plugin-root]

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REAL_PLUGIN="${1:-$(cd "$HERE/../.." && pwd)}"

ROOT=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

PLUGIN="$ROOT/plugin"
mkdir -p "$PLUGIN/lib" "$PLUGIN/framework-files"
cp "$REAL_PLUGIN/lib/manifest-keys.mjs" "$REAL_PLUGIN/lib/myspec-config.mjs" "$REAL_PLUGIN/lib/myspec-config.schema.json" "$REAL_PLUGIN/lib/plugin-root.mjs" "$REAL_PLUGIN/lib/memory-files.mjs" "$REAL_PLUGIN/lib/markdown.mjs" "$PLUGIN/lib/"
cat > "$PLUGIN/framework-files/manifest.json" <<'EOF'
{
  "frameworkVersion": "3.9.0",
  "files": {
    "style.md": { "type": "overwrite", "renamedFrom": "rules/style.md" },
    "templates/log.md": { "type": "overwrite", "renamedFrom": "templates/session-log.md" },
    "plain.md": { "type": "marker-merge" }
  },
  "rules": {
    "flow.md": { "type": "overwrite", "dest": ".claude/rules/flow.md", "renamedFrom": "rules/workflow.md" },
    "notes.md": { "type": "overwrite", "dest": ".claude/rules/notes.md", "renamedFrom": "notes.md" }
  }
}
EOF

REPO="$ROOT/proj"
mkdir -p "$REPO"
git init -q -b main "$REPO"
printf '{\n  "aiDir": "docs/ai"\n}\n' > "$REPO/.myspec.json"

OUT=$(node "$PLUGIN/lib/manifest-keys.mjs" renames --root "$REPO" --plugin-root "$PLUGIN" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok || fail "renames exits 0 (rc=$RC: $OUT)"
expect_row() {  # expect_row <row> <desc>
  if printf '%s\n' "$OUT" | grep -qxF -- "$1"; then ok; else fail "$2: no row '$1' in"$'\n'"$OUT"; fi
}
expect_row $'rules/style.md\t.claude/rules/style.md\tstyle.md\tdocs/ai/style.md' "a rule renamed to an aiDir file resolves the old key in the rules block"
expect_row $'templates/session-log.md\tdocs/ai/.templates/session-log.md\ttemplates/log.md\tdocs/ai/.templates/log.md' "a template rename keeps .templates/"
expect_row $'rules/workflow.md\t.claude/rules/workflow.md\trules/flow.md\t.claude/rules/flow.md' "a rule renamed to a rule resolves the old dest without its (gone) entry"
expect_row $'notes.md\tdocs/ai/notes.md\trules/notes.md\t.claude/rules/notes.md' "an aiDir file renamed to a rule"
[ "$(printf '%s\n' "$OUT" | grep -c .)" -eq 4 ] && ok || fail "one row per renamedFrom entry, none for plain ones (got: $OUT)"

# No .myspec.json aiDir: the schema default, as every other reader uses.
printf '{}\n' > "$REPO/.myspec.json"
OUT=$(node "$PLUGIN/lib/manifest-keys.mjs" renames --root "$REPO" --plugin-root "$PLUGIN" 2>&1)
DEFAULT=$(jq -r '.keys.aiDir.default' "$PLUGIN/lib/myspec-config.schema.json" | sed 's#^\./##; s#/*$##')
expect_row "rules/style.md	.claude/rules/style.md	style.md	$DEFAULT/style.md" "an unset aiDir resolves to the schema default"

# aiDir "./" normalises to empty, which aiDirFor (the doctor's reader) treats
# as unset. A copy of the normalisation sent every aiDir dest to "/<name>".
printf '{\n  "aiDir": "./"\n}\n' > "$REPO/.myspec.json"
OUT=$(node "$PLUGIN/lib/manifest-keys.mjs" renames --root "$REPO" --plugin-root "$PLUGIN" 2>&1)
expect_row "rules/style.md	.claude/rules/style.md	style.md	$DEFAULT/style.md" "aiDir ./ resolves as aiDirFor does, to the schema default"
printf '{}\n' > "$REPO/.myspec.json"

# A malformed manifest is the documented exit 2, not a stack trace and 1.
BAD="$ROOT/bad-plugin"
mkdir -p "$BAD/framework-files"
printf '{"files": {\n' > "$BAD/framework-files/manifest.json"
ERR=$(node "$PLUGIN/lib/manifest-keys.mjs" renames --root "$REPO" --plugin-root "$BAD" 2>&1 >/dev/null); RC=$?
[ "$RC" -eq 2 ] && ok || fail "a malformed manifest exits 2 (rc=$RC: $ERR)"
case "$ERR" in *"    at "*) fail "a malformed manifest prints no stack trace: $ERR" ;; *) ok ;; esac

node "$PLUGIN/lib/manifest-keys.mjs" --root "$REPO" --plugin-root "$PLUGIN" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && ok || fail "no command is a usage error (rc=$RC)"
node "$PLUGIN/lib/manifest-keys.mjs" renames --bogus >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && ok || fail "an unknown flag is a usage error (rc=$RC)"
node "$PLUGIN/lib/manifest-keys.mjs" renames --root "$REPO" --plugin-root "$ROOT/nowhere" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && ok || fail "a missing manifest exits 2 (rc=$RC)"

# The real manifest: the first cross-block rename (#459's move) resolves.
OUT=$(node "$REAL_PLUGIN/lib/manifest-keys.mjs" renames --root "$REPO" --plugin-root "$REAL_PLUGIN" 2>&1)
expect_row "rules/auto-memory-style.md	.claude/rules/auto-memory-style.md	auto-memory-style.md	$DEFAULT/auto-memory-style.md" "the real manifest's auto-memory-style move is a cross-block rename"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
