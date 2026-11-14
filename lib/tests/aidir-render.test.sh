#!/usr/bin/env bash
# Tests for lib/aidir-render.mjs, the one rule init, update, setup-doctor and
# pin-reconcile render a framework document by (#464): `${aiDir}` becomes the
# project's value and `$${aiDir}` a literal `${aiDir}`.
#
# Usage: aidir-render.test.sh [path-to-script]

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${1:-$HERE/../aidir-render.mjs}"
PLUGIN=$(cd "$HERE/../.." && pwd)

if [ ! -f "$SCRIPT" ]; then
  echo "FATAL: script not found: $SCRIPT" >&2
  exit 1
fi

ROOT=$(cd "$(mktemp -d)" && pwd -P)
REPO="$ROOT/proj"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$REPO"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

run() { OUTPUT=$(cd "$REPO" && node "$SCRIPT" "$@" 2>&1); STATUS=$?; }
expect() {  # expect <expected output> <description>
  if [ "$STATUS" -eq 0 ] && [ "$OUTPUT" = "$1" ]; then ok; else fail "$2 (exit $STATUS, got: $OUTPUT)"; fi
}

SRC="$ROOT/src.md"

# ═══ the rule ════════════════════════════════════════════════════════════════

printf '{"aiDir": ".ai/"}\n' > "$REPO/.myspec.json"

# shellcheck disable=SC2016 # literal text, not an expansion
printf 'a `${aiDir}/x` b ${aiDir}${aiDir}\n' > "$SRC"
run "$SRC"
# shellcheck disable=SC2016 # literal text, not an expansion
expect 'a `.ai/x` b .ai.ai' "every placeholder takes the configured value, trailing slash dropped"

# shellcheck disable=SC2016 # literal text, not an expansion
printf 'use `$${aiDir}/f` not `${aiDir}/f`\n' > "$SRC"
run "$SRC"
# shellcheck disable=SC2016 # literal text, not an expansion
expect 'use `${aiDir}/f` not `.ai/f`' "\$\${aiDir} stays a literal placeholder beside a rendered one"

# shellcheck disable=SC2016 # literal text, not an expansion
printf '$$${aiDir} $aiDir {aiDir}\n' > "$SRC"
run "$SRC"
# shellcheck disable=SC2016 # literal text, not an expansion
expect '$${aiDir} $aiDir {aiDir}' "only the exact forms are rendered: one extra \$ before the escape is kept"

printf '{"aiDir": "a$&b"}\n' > "$REPO/.myspec.json"
# shellcheck disable=SC2016 # literal text, not an expansion
printf '${aiDir}\n' > "$SRC"
run "$SRC"
# shellcheck disable=SC2016 # literal text, not an expansion
expect 'a$&b' "a value with replacement-pattern characters is written as is"

rm "$REPO/.myspec.json"
run "$SRC"
DEFAULT=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).keys.aiDir.default)' "$PLUGIN/lib/myspec-config.schema.json")
expect "$DEFAULT" "no .myspec.json renders the schema default"

mkdir -p "$ROOT/other"
printf '{"aiDir": "docs/ai"}\n' > "$ROOT/other/.myspec.json"
run "$SRC" --root "$ROOT/other"
expect 'docs/ai' "--root reads that project's aiDir"

# ═══ the shipped document that needs the escape ══════════════════════════════

printf '{"aiDir": ".ai"}\n' > "$REPO/.myspec.json"
run "$PLUGIN/framework-files/rules/paths.md"
# shellcheck disable=SC2016 # literal text, not an expansion
grep -qF '| Framework-managed doc (during skill or blueprint authoring) | `${aiDir}/features/foo/spec.md` |' <<<"$OUTPUT" && ok \
  || fail "rules/paths.md keeps the literal placeholder in its Use column"
grep -qF '  - .ai/**' <<<"$OUTPUT" && ok || fail "rules/paths.md still renders its paths: glob"
# shellcheck disable=SC2016 # literal text, not an expansion
grep -qF '$$' <<<"$OUTPUT" && fail "rendered rules/paths.md carries no escape" || ok

# ═══ usage ═══════════════════════════════════════════════════════════════════

run
[ "$STATUS" -eq 2 ] && ok || fail "no source exits 2 (got $STATUS)"
run "$ROOT/missing.md"
[ "$STATUS" -eq 2 ] && ok || fail "an unreadable source exits 2 (got $STATUS)"
run "$SRC" --bogus
[ "$STATUS" -eq 2 ] && ok || fail "an unknown flag exits 2 (got $STATUS)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
