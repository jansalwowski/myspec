#!/usr/bin/env bash
# End-to-end fixture for #451: guard-worktree-context.sh reads a Bash write
# to `~/x` as a write under $HOME, not under the repository it runs from.
# Before the fix `rm ~/d/CLAUDE.md` from the main checkout resolved to
# `<repo>/~/d/CLAUDE.md` and was blocked with the isolation question. A
# quoted '~/x' is a literal relative path in bash, so it still is.
# Usage: bash-write-targets-tilde.test.sh [path-to-hook]

set -uo pipefail

HOOK="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../guard-worktree-context.sh}"
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$HOOK")/.." && pwd)}"

if [ ! -x "$HOOK" ]; then
  echo "FATAL: hook not executable: $HOOK" >&2
  exit 1
fi

# `pwd -P`: on macOS $TMPDIR is under /var, a symlink to /private/var.
FX=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/bwt-tilde.XXXXXX")
trap 'rm -rf "$FX"' EXIT
REPO="$FX/checkout"
# Never the real home, and outside the repository.
export HOME="$FX/home"
mkdir -p "$HOME/d" "$REPO/.claude/state/sessions"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
git -C "$REPO" commit -q --allow-empty -m init
printf '{"aiDir":".ai","frameworkVersion":"2.0.0"}\n' > "$REPO/.myspec.json"

PASS=0
FAIL=0

check() {  # check <want allow|block> <desc> <command>, from $REPO, no isolation decision
  local out rc got
  out=$(printf '{"tool_input":{"command":%s},"cwd":%s,"session_id":"tilde-sess"}' \
    "$(printf '%s' "$3" | jq -Rs .)" "$(printf '%s' "$REPO" | jq -Rs .)" | "$HOOK")
  rc=$?
  if printf '%s' "$out" | grep -q '"deny"'; then got=block
  elif [ "$rc" -eq 0 ] && [ -z "$out" ]; then got=allow
  else got=noisy; fi
  if [ "$got" = "$1" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL  want=%-5s got=%-5s  %s\n      cmd: %s\n      rc=%s stdout: %s\n' \
      "$1" "$got" "$2" "$3" "$rc" "$out" >&2
  fi
}

check block "a relative write in the main checkout asks the isolation question" 'rm d/CLAUDE.md'
check allow "rm ~/x writes under \$HOME, outside the repository" 'rm ~/d/CLAUDE.md'
check allow "a redirect to ~/x writes under \$HOME" 'echo x > ~/d/notes.md'
check block "a quoted ~/x is a relative path in the repository" "rm '~/d/CLAUDE.md'"
check block "~+ is the current directory, the main checkout" 'rm ~+/CLAUDE.md'
check block "dd of= a quoted ~/x writes in the repository" "dd if=/dev/null of='~/d/x'"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
