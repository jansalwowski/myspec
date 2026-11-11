#!/usr/bin/env bash
# lib/tests/failing-tool.sh
# lint: sourced by test suites under set -uo pipefail; never run.
#
# failing_tool <dir> <tool> <needle> -> a <tool> in <dir> that exits 2 when
# one of its arguments holds <needle>, and runs the real <tool> otherwise.
# Put <dir> first on PATH to make one command inside a check fail, as a
# broken or missing tool would.
failing_tool() {
  mkdir -p "$1"
  # shellcheck disable=SC2016 # the wrapper's own $@ and $a, expanded when it runs
  printf '#!/bin/sh\nfor a in "$@"; do case "$a" in *"%s"*) exit 2 ;; esac; done\nexec "%s" "$@"\n' "$3" "$(command -v "$2")" > "$1/$2"
  chmod +x "$1/$2"
}
