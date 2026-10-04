#!/usr/bin/env bash
# dependency-map.sh
# Sourced, never run. Which dependency directories a checkout may link from
# another one, and which lockfiles pin each: shared by
# lib/worktree-provision.sh, which makes the links, and
# hooks/verify-before-stop.sh, which refuses a stop when a link no longer
# matches. Until both sourced the lib directory this block was copied into
# each, and a test kept the copies byte-identical.
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
# shellcheck disable=SC2034 # read by verify-before-stop.sh, which sources this file
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
# thousands of links costs no fork per link. A find that cannot run the
# scan (one without -mindepth, say) counts as loading: an unscanned tree is
# never accepted. The scan's own exit status is ignored: find also fails on
# an unreadable directory inside the tree, after listing every link it
# could read, and that failure says nothing about those links.
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
  find "$real" -mindepth 1 -maxdepth 0 -type l >/dev/null 2>&1 || return 0
  links=$(find "$real" -mindepth 1 -maxdepth 2 -type l 2>/dev/null || true)
  read -ra nests <<< "$NESTED_LINK_DIRS"
  for nested in ${nests[@]+"${nests[@]}"}; do
    [ -d "$real/$nested" ] || continue
    links="$links"$'\n'$(find "$real/$nested" -mindepth 1 -maxdepth 2 -type l 2>/dev/null || true)
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
