#!/usr/bin/env bash
# Deterministic tests for evals/_fixtures/lib.sh: myspec_init must scaffold
# both HEAD's tree and an older release's tree. release-check re-runs the
# previous tag with HEAD's evals/ copied in, so a framework file added since
# then is absent there (v2.10.0 release: work-isolation.md, #241).
#
# Usage: scripts/tests/eval-fixtures-lib.test.sh

set -uo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
nok() { fail=$((fail + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     /'; }

# plugin_tree <dir>: a plugin root holding what myspec_init reads.
plugin_tree() {
  mkdir -p "$1/evals"
  cp -R "$SRC_ROOT/framework-files" "$SRC_ROOT/scaffolding" "$1/"
  cp -R "$SRC_ROOT/evals/_fixtures" "$1/evals/"
}

# scaffold <plugin-root> <workspace>: run myspec_init the way a fixture.sh does.
scaffold() {
  mkdir -p "$2"
  (cd "$2" && bash -c '. "$1/evals/_fixtures/lib.sh" && myspec_init' _ "$1") 2>&1
}

plugin_tree "$TMP/head"
if out=$(scaffold "$TMP/head" "$TMP/ws-head"); then ok "HEAD tree scaffolds"; else nok "HEAD tree scaffolds" "$out"; fi
if [ -f "$TMP/ws-head/.ai/work-isolation.md" ]; then ok "HEAD tree gets work-isolation.md"; else nok "HEAD tree gets work-isolation.md"; fi

plugin_tree "$TMP/old"
rm "$TMP/old/framework-files/work-isolation.md"
if out=$(scaffold "$TMP/old" "$TMP/ws-old"); then ok "a tree without work-isolation.md scaffolds"; else nok "a tree without work-isolation.md scaffolds" "$out"; fi
if [ ! -e "$TMP/ws-old/.ai/work-isolation.md" ]; then ok "nothing is invented for the older tree"; else nok "nothing is invented for the older tree"; fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
