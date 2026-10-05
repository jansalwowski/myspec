#!/usr/bin/env bash
# Lint the JS this plugin ships with eslint:recommended (#208). The hooks and
# skills run lib/ from the plugin in every consumer's sessions (since 3.0 it is
# no longer copied into projects, #272), so a defect here ships everywhere.
#
# The repo has no package.json, so eslint runs through npx at pinned versions.
# CI (.github/workflows/test.yml) and .githooks/pre-commit both call this
# script, so the pins live in one place. Rules: eslint.config.mjs.
#
# Usage: scripts/lint-js.sh [path...]   default: lib
#        scripts/lint-js.sh --version   check that the pinned eslint can run
# Exit:  eslint's own (0 clean, 1 findings, 2 config or internal error), or
#        npx's when it cannot fetch the packages.

set -uo pipefail

ESLINT=eslint@10.11.0
ESLINT_JS=@eslint/js@10.0.1
GLOBALS=globals@17.12.0

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[ $# -gt 0 ] || set -- lib

exec npx --yes -p "$ESLINT" -p "$ESLINT_JS" -p "$GLOBALS" \
  eslint --config "$root/eslint.config.mjs" --no-warn-ignored "$@"
