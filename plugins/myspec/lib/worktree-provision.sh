#!/usr/bin/env bash
# worktree-provision.sh
# Gives a freshly created linked worktree the shared state a bare checkout
# lacks, so lint and tests can run there immediately (issue #11: subagent
# worktrees are bare — no node_modules, no lint cache — and every agent
# re-invented the same workaround inside its prompt).
#
# Usage:
#   .claude/lib/worktree-provision.sh <worktree-path> [--base <ref>] [--main <path>]
#
# What it does, from the MAIN checkout into the worktree:
#   - symlinks each entry of `isolation.provision.symlink` (default:
#     node_modules) that exists in the main checkout and is absent in the
#     worktree, and lists it in the worktree's info/exclude so it is never
#     staged
#   - copies each entry of `isolation.provision.copy` (default: .eslintcache)
#     the same way — a copy, not a link, for anything a build writes to
#   - SKIPS the node_modules symlink when the branch changes a lockfile
#     relative to --base: a symlinked tree then describes the wrong
#     dependencies, and the right answer is a real install
#
# Never symlink a build output directory (.nuxt, dist, .next): a later build in
# the worktree would write through into the main checkout. Copy the single
# generated file the linter needs instead (`copy`).
#
# The Stop hook refuses to verify a tree whose node_modules is a symlink unless
# `.myspec.json` sets isolation.allowLinkedModules: true (or the session sets
# MYSPEC_ALLOW_LINKED_MODULES=1). Recipe: skills/_shared/worktree-provisioning.md

set -euo pipefail

WORKTREE=""
BASE=""
MAIN=""

while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="${2:-}"; shift 2 ;;
    --main) MAIN="${2:-}"; shift 2 ;;
    -*) echo "worktree-provision: unknown argument '$1'" >&2; exit 1 ;;
    *) WORKTREE="$1"; shift ;;
  esac
done

if [ -z "$WORKTREE" ] || [ ! -d "$WORKTREE" ]; then
  echo "usage: worktree-provision.sh <worktree-path> [--base <ref>] [--main <path>]" >&2
  exit 1
fi

WORKTREE=$(cd "$WORKTREE" && pwd -P)

if [ -z "$MAIN" ]; then
  COMMON=$(git -C "$WORKTREE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || printf '')
  if [ -n "$COMMON" ] && [ "$(basename "$COMMON")" = ".git" ]; then
    MAIN=$(dirname "$COMMON")
  fi
fi

if [ -z "$MAIN" ] || [ ! -d "$MAIN" ]; then
  echo "worktree-provision: cannot resolve the main checkout — pass --main <path>" >&2
  exit 1
fi

if [ "$MAIN" = "$WORKTREE" ]; then
  echo "worktree-provision: '$WORKTREE' is the main checkout, not a linked worktree" >&2
  exit 1
fi

SYMLINK=()
COPY=()

if [ -f "$MAIN/.myspec.json" ] && command -v jq >/dev/null 2>&1; then
  while IFS= read -r entry; do [ -n "$entry" ] && SYMLINK+=("$entry"); done \
    < <(jq -r '.isolation.provision.symlink // ["node_modules"] | .[] | select(type == "string")' "$MAIN/.myspec.json" 2>/dev/null)
  while IFS= read -r entry; do [ -n "$entry" ] && COPY+=("$entry"); done \
    < <(jq -r '.isolation.provision.copy // [".eslintcache"] | .[] | select(type == "string")' "$MAIN/.myspec.json" 2>/dev/null)
else
  SYMLINK=(node_modules)
  COPY=(.eslintcache)
fi

EXCLUDE_FILE=$(git -C "$WORKTREE" rev-parse --git-path info/exclude)
mkdir -p "$(dirname "$EXCLUDE_FILE")"

exclude() {
  if ! grep -qxF -- "$1" "$EXCLUDE_FILE" 2>/dev/null; then
    printf '%s\n' "$1" >> "$EXCLUDE_FILE"
  fi
}

# A branch that changes a lockfile has different dependencies from the main
# checkout; a symlinked node_modules would then verify the wrong tree.
LOCKFILE_CHANGED=0
if [ -n "$BASE" ]; then
  if git -C "$WORKTREE" rev-parse --verify --quiet "$BASE" >/dev/null 2>&1; then
    if git -C "$WORKTREE" diff --name-only "$BASE...HEAD" -- \
        package-lock.json yarn.lock pnpm-lock.yaml bun.lockb bun.lock \
        composer.lock poetry.lock Pipfile.lock Cargo.lock Gemfile.lock go.sum 2>/dev/null | grep -q .; then
      LOCKFILE_CHANGED=1
    fi
  fi
fi

LINKED=0
COPIED=0

# ${arr[@]+"${arr[@]}"}: an empty array is "unbound" under set -u in bash < 4.4
for entry in ${SYMLINK[@]+"${SYMLINK[@]}"}; do
  entry="${entry%/}"
  if [ "$entry" = "node_modules" ] && [ "$LOCKFILE_CHANGED" -eq 1 ]; then
    echo "worktree-provision: lockfile differs from $BASE — not linking node_modules; run a real install in the worktree"
    continue
  fi
  if [ -e "$MAIN/$entry" ] && [ ! -e "$WORKTREE/$entry" ]; then
    mkdir -p "$(dirname "$WORKTREE/$entry")"
    ln -s "$MAIN/$entry" "$WORKTREE/$entry"
    exclude "$entry"
    LINKED=$(( LINKED + 1 ))
  fi
done

for entry in ${COPY[@]+"${COPY[@]}"}; do
  entry="${entry%/}"
  if [ -f "$MAIN/$entry" ] && [ ! -e "$WORKTREE/$entry" ]; then
    mkdir -p "$(dirname "$WORKTREE/$entry")"
    # /bin/cp, not cp — `cp` is shadowed by a shell alias in some environments.
    /bin/cp -p "$MAIN/$entry" "$WORKTREE/$entry"
    exclude "$entry"
    COPIED=$(( COPIED + 1 ))
  fi
done

echo "worktree-provision: $LINKED symlinked, $COPIED copied into $WORKTREE"
