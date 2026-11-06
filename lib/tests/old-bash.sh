#!/usr/bin/env bash
# lib/tests/old-bash.sh
# lint: sourced by test suites under set -uo pipefail; never run.
#
# Bash before 4.4 calls an empty "${a[@]}" unbound under set -u (#378), and
# macOS ships 3.2 as /bin/bash. A suite whose script runs through
# `#!/usr/bin/env bash` passes under a newer bash and still crashes there.
#
# old_bash_dirs <scratch dir> -> sets TEST_BASH_DIRS to the PATH prefixes to
# run each case under: "" (the bash on PATH), plus a directory holding a
# `bash` shim to /bin/bash when that bash is older than 4.4 and is not the
# one on PATH already. Put a prefix first on PATH and every `env bash` in the
# script under test, and in the scripts it runs, resolves to that bash.
# Linux has no such bash, so there the list holds the default only.
old_bash_dirs() {
  local path_ver old_ver
  TEST_BASH_DIRS=("")
  old_ver=$(/bin/bash -c '[ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; } && printf %s "$BASH_VERSION"' 2>/dev/null) || return 0
  path_ver=$(bash -c 'printf %s "$BASH_VERSION"' 2>/dev/null) || path_ver=""
  [ "$path_ver" != "$old_ver" ] || return 0
  mkdir -p "$1/old-bash"
  ln -sf /bin/bash "$1/old-bash/bash"
  TEST_BASH_DIRS+=("$1/old-bash")
}
