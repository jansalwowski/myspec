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
#   - SKIPS a symlink entry when the branch changes one of the lockfiles
#     that pin it relative to --base: a symlinked tree then describes the
#     wrong dependencies, and the right answer is a real install. Which
#     lockfiles pin which entry is the dependency-lockfile map below.
#
# Never symlink a build output directory (.nuxt, dist, .next): a later build in
# the worktree would write through into the main checkout. Copy the single
# generated file the linter needs instead (`copy`).
#
# The Stop hook accepts a symlinked dependency directory only when the
# lockfiles that pin it are byte-identical to the checkout the link points
# into (the case this script links), unless `.myspec.json` sets
# isolation.allowLinkedModules: true (or the session sets
# MYSPEC_ALLOW_LINKED_MODULES=1).
# Recipe: skills/_shared/worktree-provisioning.md

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

# BEGIN dependency-lockfile map
# Byte-identical in hooks/verify-before-stop.sh and lib/worktree-provision.sh
# (the two ship separately, so neither can source the other); a test in
# lib/tests/worktree-provision.test.sh fails when they drift.
#
# An isolation.provision.symlink entry is a string ("vendor") or an object
# ({"path": "vendor", "lockfiles": ["composer.lock"]}). An object with
# "lockfiles" names the files that pin that tree, repo-relative, globs allowed;
# "lockfiles": [] declares it unguarded. A string, or an object without
# "lockfiles", takes the lockfiles of a well-known dependency directory from
# dep_lockfiles below, looked up by the entry basename and matched both beside
# the entry and at the repo root (a nested apps/web/node_modules is pinned by
# either). Anything else (an .env file, a cache) is unguarded: it pins no
# dependency set, and guarding it would block every stop that links one.
DEP_DIRS="node_modules vendor .venv venv"

# dep_lockfiles <basename> -> the lockfile names that pin that directory.
# vendor is shared by Composer, Bundler and Go modules, so it lists all three;
# only the lockfiles that exist take part in a comparison.
dep_lockfiles() {
  case "$1" in
    node_modules) printf '%s\n' package-lock.json npm-shrinkwrap.json yarn.lock pnpm-lock.yaml bun.lockb bun.lock ;;
    vendor) printf '%s\n' composer.lock Gemfile.lock go.sum ;;
    .venv|venv) printf '%s\n' poetry.lock Pipfile.lock uv.lock pdm.lock 'requirements*.txt' ;;
  esac
}

# infer_entry <path> -> "path<TAB>lockfile<TAB>..." from the built-in map.
infer_entry() {
  local path="$1" parent lock line
  parent=$(dirname "$path")
  line="$path"
  while IFS= read -r lock; do
    [ -n "$lock" ] || continue
    [ "$parent" = "." ] || line="$line"$'\t'"$parent/$lock"
    line="$line"$'\t'"$lock"
  done < <(dep_lockfiles "$(basename "$path")")
  printf '%s\n' "$line"
}

# symlink_entries <.myspec.json> -> one "path<TAB>lockfile<TAB>..." line per
# configured entry; a line with no lockfile is an unguarded entry. A missing
# config means the default ["node_modules"]; an unreadable one means none.
symlink_entries() {
  local raw line path mode rest
  if [ -f "$1" ] && command -v jq >/dev/null 2>&1; then
    raw=$(jq -r '(.isolation.provision.symlink // ["node_modules"])[]
      | if type == "string" then [., "-"]
        elif type == "object" and (.path | type) == "string" then
          if has("lockfiles") then [.path, "="] + [(.lockfiles // [])[] | select(type == "string")]
          else [.path, "-"] end
        else empty end
      | @tsv' "$1" 2>/dev/null) || raw=""
  else
    raw=$'node_modules\t-'
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    path="${line%%$'\t'*}"
    rest="${line#*$'\t'}"
    mode="${rest%%$'\t'*}"
    path="${path%/}"
    [ -n "$path" ] || continue
    if [ "$mode" = "-" ]; then
      infer_entry "$path"
    elif [ "$rest" = "=" ]; then
      printf '%s\n' "$path"
    else
      printf '%s\t%s\n' "$path" "${rest#=$'\t'}"
    fi
  done <<< "$raw"
}
# END dependency-lockfile map

COPY=()

if [ -f "$MAIN/.myspec.json" ] && command -v jq >/dev/null 2>&1; then
  while IFS= read -r entry; do [ -n "$entry" ] && COPY+=("$entry"); done \
    < <(jq -r '.isolation.provision.copy // [".eslintcache"] | .[] | select(type == "string")' "$MAIN/.myspec.json" 2>/dev/null)
else
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
# checkout; a symlinked dependency tree would then verify the wrong one.
BASE_OK=0
if [ -n "$BASE" ] && git -C "$WORKTREE" rev-parse --verify --quiet "$BASE" >/dev/null 2>&1; then
  BASE_OK=1
fi

LINKED=0
COPIED=0

while IFS= read -r line; do
  [ -n "$line" ] || continue
  entry="${line%%$'\t'*}"
  LOCKS=()
  if [ "$line" != "$entry" ]; then
    IFS=$'\t' read -ra LOCKS <<< "${line#*$'\t'}"
  fi
  # ${arr[@]+"${arr[@]}"}: an empty array is "unbound" under set -u in bash < 4.4
  if [ "$BASE_OK" -eq 1 ] && [ "${#LOCKS[@]}" -gt 0 ] \
      && git -C "$WORKTREE" diff --name-only "$BASE...HEAD" -- ${LOCKS[@]+"${LOCKS[@]}"} 2>/dev/null | grep -q .; then
    echo "worktree-provision: lockfile differs from $BASE — not linking $entry; run a real install in the worktree"
    continue
  fi
  if [ -e "$MAIN/$entry" ] && [ ! -e "$WORKTREE/$entry" ]; then
    mkdir -p "$(dirname "$WORKTREE/$entry")"
    ln -s "$MAIN/$entry" "$WORKTREE/$entry"
    exclude "$entry"
    LINKED=$(( LINKED + 1 ))
  fi
done < <(symlink_entries "$MAIN/.myspec.json")

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
