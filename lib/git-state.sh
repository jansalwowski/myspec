#!/usr/bin/env bash
# git-state.sh
# Prints the git signals skills/_shared/git-helpers.md lists, in one call
# (#488): feature-spec, feature-plan and feature-implement each ran the same
# four to seven git commands one turn at a time.
#
# Usage:
#   "${CLAUDE_PLUGIN_ROOT}"/lib/git-state.sh [<feature-name>]
#
# Output, one "key: value" line each:
#   default: <branch>            the default branch, from the cascade
#                                origin/HEAD, then main, then master;
#                                `unknown` when none resolves (ask the user)
#   head: <branch>               the current branch (`HEAD` when detached)
#   tree: clean | dirty          then, when dirty, each `git status
#                                --porcelain` line indented by two spaces
# With <feature-name> also:
#   worktree: <path> | none      a worktree whose path ends in feat-<name>
#   branch: exists | absent      whether feat/<name> exists locally
#
# Exit 1 outside a git checkout or on a bad name; nothing is printed then.

set -euo pipefail

die() { echo "git-state: $*" >&2; exit 1; }

[ $# -le 1 ] || die "usage: git-state.sh [<feature-name>]"
NAME="${1:-}"
if [ -n "$NAME" ] && ! [[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  die "invalid feature name: '$NAME'"
fi
git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git checkout"

default=$(git symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@') || default=""
if [ -z "$default" ]; then
  if git rev-parse --verify -q main >/dev/null; then default=main
  elif git rev-parse --verify -q master >/dev/null; then default=master
  else default=unknown
  fi
fi
printf 'default: %s\n' "$default"
# symbolic-ref, not rev-parse --abbrev-ref: on an unborn branch that prints
# `HEAD` and exits 128, so a fallback would add a second line.
printf 'head: %s\n' "$(git symbolic-ref -q --short HEAD 2>/dev/null || echo HEAD)"

status=$(git status --porcelain)
if [ -z "$status" ]; then
  echo "tree: clean"
else
  echo "tree: dirty"
  printf '%s\n' "$status" | sed 's/^/  /'
fi

[ -n "$NAME" ] || exit 0
wt=$(git worktree list --porcelain | sed -n 's/^worktree //p' |
  awk -v suf="/feat-$NAME" '!f && length($0) > length(suf) && substr($0, length($0) - length(suf) + 1) == suf { print; f = 1 }')
printf 'worktree: %s\n' "${wt:-none}"
if git rev-parse --verify -q "refs/heads/feat/$NAME" >/dev/null; then
  echo "branch: exists"
else
  echo "branch: absent"
fi
