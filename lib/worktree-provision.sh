#!/usr/bin/env bash
# worktree-provision.sh
# Gives a freshly created linked worktree the shared state a bare checkout
# lacks, so lint and tests can run there immediately (issue #11: subagent
# worktrees are bare — no node_modules, no lint cache — and every agent
# re-invented the same workaround inside its prompt).
#
# Usage:
#   .claude/lib/worktree-provision.sh <worktree-path> [--base <ref>] [--main <path>] [--no-symlink]
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
#     lockfiles pin which entry is the dependency-lockfile map below. Also
#     skips a tree that loads the project's own source from the main checkout
#     (a Composer vendor, a .venv with an editable install): through a link,
#     the worktree's checks would run the main checkout's code.
#   - SKIPS every symlink entry under --no-symlink: a step that writes into
#     a linked directory (code generation into node_modules, vendor, .venv,
#     ...) would write through the link into the source checkout (issue #93)
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
NO_SYMLINK=0

while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="${2:-}"; shift 2 ;;
    --main) MAIN="${2:-}"; shift 2 ;;
    --no-symlink) NO_SYMLINK=1; shift ;;
    -*) echo "worktree-provision: unknown argument '$1'" >&2; exit 1 ;;
    *) WORKTREE="$1"; shift ;;
  esac
done

if [ -z "$WORKTREE" ] || [ ! -d "$WORKTREE" ]; then
  echo "usage: worktree-provision.sh <worktree-path> [--base <ref>] [--main <path>] [--no-symlink]" >&2
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
# "lockfiles" names the files that pin that tree, repo-relative, globs allowed
# (a * stays within one directory, as in the shell); "lockfiles": [] declares
# it unguarded. A string, or an object without a usable "lockfiles", takes the
# lockfiles of a well-known dependency directory from dep_lockfiles below and
# matches them both beside the project that owns the entry and at the repo
# root (a nested apps/web/node_modules is pinned by either). Anything else (an
# .env file, a cache) is unguarded: it pins no dependency set, and guarding it
# would block every stop that links one.
# DEP_DIRS entries are repo-relative; a * stays within one directory and is
# expanded against the checkout root (vendor-bin/*/vendor: the per-tool vendor
# trees the Composer bin plugin installs).
# shellcheck disable=SC2034 # only verify-before-stop.sh reads it; the block is byte-identical in both files
DEP_DIRS="node_modules vendor vendor/bundle vendor-bin/*/vendor .venv venv"

# dep_lockfiles <path> -> the lockfile names that pin that directory.
# vendor is shared by Composer, Bundler and Go modules, so it lists all three;
# only the lockfiles that exist take part in a comparison. vendor/bundle is
# Bundler's own install path, keyed by path because "bundle" alone is generic.
dep_lockfiles() {
  case "$1" in
    vendor/bundle|*/vendor/bundle) printf '%s\n' Gemfile.lock; return ;;
  esac
  case "${1##*/}" in
    node_modules) printf '%s\n' package-lock.json npm-shrinkwrap.json yarn.lock pnpm-lock.yaml bun.lockb bun.lock ;;
    vendor) printf '%s\n' composer.lock Gemfile.lock go.sum ;;
    .venv|venv) printf '%s\n' poetry.lock Pipfile.lock uv.lock pdm.lock 'requirements*.txt' ;;
  esac
}

# infer_entry <path> -> "path<TAB>lockfile<TAB>..." from the built-in map.
infer_entry() {
  local path="$1" parent lock line
  case "$path" in
    vendor/bundle|*/vendor/bundle) parent=$(dirname "$(dirname "$path")") ;;
    *) parent=$(dirname "$path") ;;
  esac
  line="$path"
  while IFS= read -r lock; do
    [ -n "$lock" ] || continue
    [ "$parent" = "." ] || line="$line"$'\t'"$parent/$lock"
    line="$line"$'\t'"$lock"
  done < <(dep_lockfiles "$path")
  printf '%s\n' "$line"
}

# symlink_entries <.myspec.json> -> one "path<TAB>lockfile<TAB>..." line per
# configured entry; a line with no lockfile is an unguarded entry. A missing
# config means the default ["node_modules"]; an unreadable one means none. A
# malformed entry is dropped on its own, never taking the others with it, and
# a "lockfiles" that is not a list falls back to the built-in map.
symlink_entries() {
  local raw line path mode rest
  if [ -f "$1" ] && command -v jq >/dev/null 2>&1; then
    raw=$(jq -r '(.isolation.provision.symlink // ["node_modules"])
      | if type == "array" then .[] elif type == "string" then . else empty end
      | if type == "string" then [., "-"]
        elif type == "object" and (.path | type) == "string" then
          (.lockfiles | if type == "array" then . elif type == "string" then [.] else null end) as $l
          | if $l == null then [.path, "-"]
            else [.path, "="] + [$l[] | select(type == "string" and . != "")] end
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
    while [ "${path#./}" != "$path" ]; do path="${path#./}"; done
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

# tree_loads_checkout <tree> <checkout> -> 0 when the dependency tree at
# <tree> loads the project's OWN source from <checkout> (a physical path).
# A link to such a tree runs that checkout's code, not this one's, however
# identical the lockfiles are. Composer writes the root package's autoload
# rules against $baseDir, which PHP resolves through the link; an editable
# Python install (poetry, uv, pip -e) records its source in direct_url.json.
# A workspace link is a directory symlink in the tree's top two levels
# (<name>, @scope/<name>, vendor/<name>), or in a nested link directory
# (NESTED_LINK_DIRS), that resolves out of the tree: an npm, Yarn, pnpm or
# Bun workspace package, a Composer path repository. A relative one resolves
# from the physical tree, so through a link it lands in the other checkout's
# packages. Every such link is resolved physically, because its text says
# little about where it lands (.., ./../x, a/../../x, or a hop into a deeper
# link that leaves the tree). The cd calls run in one subshell, so a tree of
# thousands of links costs no fork per link. A find that fails (one without
# -mindepth, say) counts as loading: an unscanned tree is never accepted.
# NESTED_LINK_DIRS are tree-relative directories that hold links of their
# own one or two levels down, such as the pnpm hidden hoist
# (.pnpm/node_modules/@scope/<name>, four levels below the tree). Data, so
# another layout is one more entry.
NESTED_LINK_DIRS=".pnpm/node_modules"
tree_loads_checkout() {
  local tree="$1" checkout="$2" f url dir real links nested
  local -a nests
  # shellcheck disable=SC2016 # the literal $baseDir text Composer writes, not a variable
  grep -qsF '$baseDir . ' "$tree"/composer/autoload_*.php && return 0
  for f in "$tree"/lib/python*/site-packages/*.dist-info/direct_url.json; do
    [ -f "$f" ] || continue
    url=$(jq -r 'select(.dir_info.editable == true) | .url // empty' "$f" 2>/dev/null) || continue
    case "$url" in file://*) ;; *) continue ;; esac
    dir=$(cd "${url#file://}" 2>/dev/null && pwd -P) || continue
    case "$dir/" in "$checkout"/*) return 0 ;; esac
  done
  real=$(cd "$tree" 2>/dev/null && pwd -P) || return 1
  links=$(find "$real" -mindepth 1 -maxdepth 2 -type l 2>/dev/null) || return 0
  read -ra nests <<< "$NESTED_LINK_DIRS"
  for nested in ${nests[@]+"${nests[@]}"}; do
    [ -d "$real/$nested" ] || continue
    links="$links"$'\n'$(find "$real/$nested" -mindepth 1 -maxdepth 2 -type l 2>/dev/null) || return 0
  done
  (
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      cd -P "$f" 2>/dev/null || continue
      case "$PWD/" in
        "$real"/*) ;;
        "$checkout"/*) exit 0 ;;
      esac
    done <<< "$links"
    exit 1
  )
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
MAIN_REAL=$(cd "$MAIN" && pwd -P)

while IFS= read -r line; do
  [ -n "$line" ] || continue
  entry="${line%%$'\t'*}"
  SPECS=()
  if [ "$line" != "$entry" ]; then
    IFS=$'\t' read -ra LOCKS <<< "${line#*$'\t'}"
    # :(glob) keeps a * inside one directory, as the Stop hook's shell glob does.
    for lock in "${LOCKS[@]}"; do SPECS+=(":(glob)$lock"); done
  fi
  # ${arr[@]+"${arr[@]}"}: an empty array is "unbound" under set -u in bash < 4.4
  if [ "$BASE_OK" -eq 1 ] && [ "${#SPECS[@]}" -gt 0 ] \
      && git -C "$WORKTREE" diff --name-only "$BASE...HEAD" -- ${SPECS[@]+"${SPECS[@]}"} 2>/dev/null | grep -q .; then
    echo "worktree-provision: lockfile differs from $BASE — not linking $entry; run a real install in the worktree"
    continue
  fi
  if tree_loads_checkout "$MAIN/$entry" "$MAIN_REAL"; then
    echo "worktree-provision: $entry loads the main checkout's own source — not linking $entry; run a real install in the worktree"
    continue
  fi
  if [ "$NO_SYMLINK" -eq 1 ]; then
    echo "worktree-provision: --no-symlink — not linking $entry; run a real install in the worktree"
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
