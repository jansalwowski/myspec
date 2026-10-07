#!/usr/bin/env bash
# Lint the JS this plugin ships with eslint:recommended (#208). The hooks and
# skills run lib/ from the plugin in every consumer's sessions (since 3.0 it is
# no longer copied into projects, #272), so a defect here ships everywhere.
#
# The repo has no package.json, so eslint runs through npx at pinned versions.
# CI (.github/workflows/test.yml) and .githooks/pre-commit both call this
# script, so the pins live in one place. Rules: eslint.config.mjs.
#
# Workflow scripts (workflows/*.js, #247) are linted too. The Workflow tool runs
# them as a module body with top-level await and a top-level `return`, which no
# eslint source type parses, so each one is fed through stdin wrapped the way
# the runtime evaluates it: inside `export default async function () {` on its
# first line (line numbers unchanged), with `export const meta` read as an
# assignment to the `meta` the runtime collects, and the runtime's globals
# declared in eslint.config.mjs.
#
# Usage: scripts/lint-js.sh [path...]   default: lib and workflows/*.js
#        scripts/lint-js.sh --version   check that the pinned eslint can run
# Exit:  eslint's own (0 clean, 1 findings, 2 config or internal error), or
#        npx's when it cannot fetch the packages.

set -uo pipefail

ESLINT=eslint@10.11.0
ESLINT_JS=@eslint/js@10.0.1
GLOBALS=globals@17.12.0

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
eslint() {
  npx --yes -p "$ESLINT" -p "$ESLINT_JS" -p "$GLOBALS" \
    eslint --config "$root/eslint.config.mjs" --no-warn-ignored "$@"
}

if [ "${1:-}" = --version ]; then
  eslint --version
  exit $?
fi

if [ $# -eq 0 ]; then
  set -- lib
  for w in "$root"/workflows/*.js; do
    [ -f "$w" ] && set -- "$@" "${w#"$root"/}"
  done
fi

plain=()
workflows=()
for p in "$@"; do
  case "$p" in
    workflows/*.js|*/workflows/*.js) workflows+=("$p") ;;
    *) plain+=("$p") ;;
  esac
done

rc=0
if [ ${#plain[@]} -gt 0 ]; then
  eslint "${plain[@]}" || rc=$?
fi
for w in ${workflows[@]+"${workflows[@]}"}; do
  # shellcheck disable=SC2016 # the JS program is literal
  wrapped=$(node -e '
    const src = require("fs").readFileSync(process.argv[1], "utf8")
    process.stdout.write("export default async function () { " + src.replace(/^export const meta\b/m, "meta") + "\n}\n")
  ' "$w") || { echo "lint-js: cannot read $w" >&2; rc=2; continue; }
  r=0
  printf '%s' "$wrapped" | eslint --stdin --stdin-filename "$w" || r=$?
  [ "$r" -le "$rc" ] || rc=$r
done
exit "$rc"
