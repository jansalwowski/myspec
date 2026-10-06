#!/usr/bin/env bash
# Regression fixture for lib/upgrade-route.mjs (3.0 dogfood).
#
# A project on 1.17.0 was refused by 3.0's update with "run v2.12.0 first",
# and v2.12.0's update then refused it with "run v1.28.0 first": the route
# came one hop at a time. The refusal now names every floor above the
# project's version, from the manifest's `upgradeChain` and `upgradeFrom`.
# Runs against the plugin's real manifest and a fixture manifest, so a floor
# bump at the next major does not break the fixture cases.
#
# Usage: upgrade-route.test.sh [path-to-script]

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${1:-$HERE/../upgrade-route.mjs}"
PLUGIN=$(cd "$HERE/../.." && pwd)

if [ ! -f "$SCRIPT" ]; then
  echo "FATAL: script not found: $SCRIPT" >&2
  exit 1
fi

ROOT=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

run() {  # run <plugin-root> <version>: sets OUTPUT and STATUS
  OUTPUT=$(node "$SCRIPT" --plugin-root "$1" --version "$2" 2>&1); STATUS=$?
}
has()    { case "$OUTPUT" in *"$1"*) ok ;; *) fail "$2 (output: $OUTPUT)" ;; esac; }
hasnt()  { case "$OUTPUT" in *"$1"*) fail "$2 (output: $OUTPUT)" ;; *) ok ;; esac; }

# Fixture: the 3.0 shape, frozen.
mkdir -p "$ROOT/plugin/framework-files"
cat > "$ROOT/plugin/framework-files/manifest.json" <<'EOF'
{ "frameworkVersion": "3.0.0", "upgradeFrom": "2.12.0", "upgradeChain": ["1.28.0"], "files": {} }
EOF
FIX="$ROOT/plugin"

# A 1.x project is sent through both floors, in order.
run "$FIX" 1.17.0
[ "$STATUS" -eq 1 ] && ok || fail "1.17.0 is refused with exit 1 (got $STATUS)"
has 'v1.28.0, then v2.12.0, then this version' "1.17.0 is given the whole route, oldest first"
has 'docs/upgrading-to-3.0.md' "the refusal points at the upgrade guide"
has 'This project is on v1.17.0' "the refusal names the recorded version"

# A 2.x project below the floor needs only the last floor.
run "$FIX" 2.5.0
[ "$STATUS" -eq 1 ] && ok || fail "2.5.0 is refused with exit 1 (got $STATUS)"
has 'Update through v2.12.0, then this version' "2.5.0 is sent through v2.12.0 only"
hasnt 'v1.28.0' "2.5.0 is not sent through v1.28.0"

# Exactly on a floor: that floor is not a step.
run "$FIX" 1.28.0
has 'Update through v2.12.0, then this version' "1.28.0 skips its own floor"

# At or above the floor: no refusal.
for v in 2.12.0 2.12.3 3.0.0; do
  run "$FIX" "$v"
  if [ "$STATUS" -eq 0 ] && [ -z "$OUTPUT" ]; then ok; else fail "$v is not refused (exit $STATUS, output: $OUTPUT)"; fi
done

# Numeric, not lexical, comparison: 2.9 < 2.12, 1.100 > 1.28.
run "$FIX" 2.9.0
has 'Update through v2.12.0, then this version' "2.9.0 compares below 2.12.0"
run "$FIX" 1.100.0
hasnt 'v1.28.0' "1.100.0 compares above 1.28.0"

# No recorded version: the whole route.
run "$FIX" ''
[ "$STATUS" -eq 1 ] && ok || fail "a missing version is refused (got $STATUS)"
has 'records no frameworkVersion' "a missing version is named as missing"
has 'v1.28.0, then v2.12.0' "a missing version gets the whole route"

# A manifest with no floor is a usage error, not a pass.
echo '{ "frameworkVersion": "3.0.0", "files": {} }' > "$ROOT/plugin/framework-files/manifest.json"
run "$FIX" 1.0.0
[ "$STATUS" -eq 2 ] && ok || fail "a manifest without upgradeFrom exits 2 (got $STATUS)"

# The shipped manifest: a project below its floor is refused and given every
# floor in upgradeChain plus upgradeFrom; one at the floor passes.
FLOOR=$(jq -r .upgradeFrom "$PLUGIN/framework-files/manifest.json")
run "$PLUGIN" 0.1.0
[ "$STATUS" -eq 1 ] && ok || fail "the shipped manifest refuses 0.1.0 (got $STATUS)"
for v in $(jq -r '(.upgradeChain // [])[], .upgradeFrom' "$PLUGIN/framework-files/manifest.json"); do
  has "v$v" "the shipped route names v$v"
done
run "$PLUGIN" "$FLOOR"
[ "$STATUS" -eq 0 ] && ok || fail "the shipped manifest accepts its floor $FLOOR (got $STATUS)"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
