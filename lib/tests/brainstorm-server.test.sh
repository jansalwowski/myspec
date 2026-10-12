#!/usr/bin/env bash
# Runs the brainstorm-server suites in lib/tests/brainstorm-server/: every
# *.test.js with node and every *.test.sh with bash, one after another (the
# server suites spawn real servers and watch real directories). Ported from
# obra/superpowers tests/brainstorm-server; no npm dependencies, so the
# WebSocket client is lib/tests/brainstorm-server/ws-client.cjs.
#
# Usage: brainstorm-server.test.sh
# Env:   BRAINSTORM_TEST_SERVER_DIR  run against another copy of
#        lib/brainstorm-server (default: the shipped one)
# Exit:  0 when every suite passed, 1 otherwise.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/brainstorm-server"
if ! command -v node >/dev/null 2>&1; then
  echo "FATAL: node not found" >&2
  exit 1
fi

failed=()
ran=0
for suite in "$DIR"/*.test.js "$DIR"/*.test.sh; do
  [ -f "$suite" ] || continue
  name="${suite#"$DIR"/}"
  echo "=== $name"
  case "$suite" in
    *.js) node "$suite" ;;
    *.sh) bash "$suite" ;;
  esac
  rc=$?
  ran=$((ran + 1))
  [ "$rc" -eq 0 ] || failed+=("$name (exit $rc)")
done

echo ""
if [ "$ran" -eq 0 ]; then
  echo "brainstorm-server: no suites found in $DIR" >&2
  exit 1
fi
if [ ${#failed[@]} -gt 0 ]; then
  printf 'brainstorm-server: FAILED %s\n' "${failed[@]}" >&2
  echo "brainstorm-server: $((ran - ${#failed[@]}))/$ran suites passed"
  exit 1
fi
echo "brainstorm-server: $ran/$ran suites passed"
