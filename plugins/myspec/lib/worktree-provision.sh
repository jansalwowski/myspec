#!/usr/bin/env bash
# worktree-provision.sh
# Gives a freshly created linked worktree the shared state a bare checkout
# lacks, so lint and tests can run there immediately (issue #11: subagent
# worktrees are bare — no node_modules, no lint cache — and every agent
# re-invented the same workaround inside its prompt).
#
# Usage:
#   .claude/lib/worktree-provision.sh <worktree-path> [--base <ref>] [--main <path>] [--no-symlink] [--no-install]
#
# Settings are .myspec.json `isolation.provision`, read through
# myspec-config.sh: from the worktree when it has a .myspec.json (the
# branch's own settings), else from the main checkout. In order:
#   1. symlink: links each entry (default: node_modules) that exists in the
#      main checkout, and lists it in the worktree's info/exclude so it is
#      never staged. A link an earlier run made is dropped and decided again,
#      so a rerun refreshes the record below. An entry with a glob
#      (vendor-bin/*/vendor) is expanded against the main checkout, a * staying
#      within one directory: each match is linked and recorded on its own, and
#      a glob that matches nothing is named. An entry is SKIPPED, with a line
#      saying why,
#      - when the branch changes one of the lockfiles that pin it relative
#        to --base, or a lockfile that pins it differs from the main
#        checkout's copy: a linked tree then describes the wrong dependencies
#        (which lockfiles pin which entry: dep_lockfiles below);
#      - when the tree loads the project's own source from the main checkout
#        (a Composer vendor, a .venv with an editable install, workspace
#        links, #229): through a link, the worktree's checks would run the
#        main checkout's code. Only a tree that holds such links is skipped,
#        whatever workspace config the repo has: a pnpm workspace's Composer
#        vendor is still linked;
#      - under --no-symlink: a step that writes into a linked directory
#        (code generation into node_modules, vendor, .venv, ...) would write
#        through the link into the source checkout (issue #93);
#      - when it is a dependency tree (DEP_DIRS) and `install` is set: the
#        install builds that tree in the worktree, and through a link it
#        would write into the main checkout;
#      - when something already exists at that path in the worktree.
#      A directory the branch tracks files in (a .gitkeep placeholder,
#      #239) cannot be replaced by a link: that is an error naming the file
#      and the fix, and provisioning stops with exit 1.
#   2. copy: copies each entry (default: .eslintcache), a file or a
#      directory (#222), for anything a build writes to. {"path": "vendor",
#      "mode": "clone"} makes a copy-on-write clone where the filesystem
#      supports one (--reflink=auto on Btrfs/XFS, cp -c on APFS) and falls
#      back to a plain copy. A directory in the worktree that holds only
#      tracked files (placeholders) is filled, not skipped.
#   3. clean: deletes the untracked files and directories in the worktree
#      that match a repo-relative glob (#193, lib/glob-regex.sh), e.g.
#      **/*.tsbuildinfo, so the
#      first incremental check there is cold. It never follows or deletes a
#      link.
#   4. install: runs a command, or each {run, cwd, when} step, in the
#      worktree (#230). cwd is repo-relative (default the root); a step runs
#      only when every repo-relative path in `when` exists. Each step sees
#      MYSPEC_WORKTREE and MYSPEC_MAIN_CHECKOUT exported, and stdin from
#      /dev/null, so a step that reads stdin cannot eat the steps after it.
#      A failing step stops provisioning with exit 1 and is never retried.
#      --no-install skips every step, prints each one, and links as if
#      install were unset.
#
# Never symlink a build output directory (.nuxt, dist, .next): a later build in
# the worktree would write through into the main checkout. Copy the single
# generated file the linter needs instead (`copy`).
#
# The record. What this script did is written to
# <worktree>/.claude/state/provision.json (listed in info/exclude):
#   {"provisionedAt": <epoch seconds>,
#    "source": "<the main checkout, physical>",
#    "links": [{"path": "node_modules", "target": "<physical link target>",
#               "lockfiles": {"package-lock.json": "<sha256>",
#                             "apps/web/package-lock.json": null}}],
#    "copies": [{"path": ".eslintcache", "mode": "copy"}],
#    "install": [{"run": "<command>", "cwd": "."}]}
# `lockfiles` holds the SHA-256 of each lockfile that pins the link, as the
# main checkout had it (the worktree's copy was identical: an entry whose
# copy differs is not linked), and each lockfile pattern that matched nothing,
# and each glob pattern, with a null hash. The Stop hook reads this record and
# nothing else about dependencies: it blocks when a recorded link no longer
# resolves to its target, a recorded lockfile's hash changed or the file is
# gone in the main checkout or in the worktree, or a null-hash pattern now
# matches a file on either side that the record does not hash (a nested
# lockfile the branch added later), and tells the session to rerun this
# script. A worktree
# without a record is not compared. isolation.allowLinkedModules: true (or
# MYSPEC_ALLOW_LINKED_MODULES=1 while this script runs) records links
# without lockfile hashes and skips the lockfile comparison above, for repos
# whose worktrees share the main checkout's dependencies by construction. A
# link the record does not list is doctor's finding (link-unrecorded).
# Recipe: skills/_shared/worktree-provisioning.md

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# checkout_facts, and glob_regex: the one glob compiler (lib/glob-regex.sh,
# which hook-core sources), shared with the Stop hook's `paths` and
# mark-code-changed's ignorePaths, so one glob means one thing.
# shellcheck source=lib/hook-core.sh
. "$HERE/hook-core.sh"
declare -F glob_regex >/dev/null || { echo "worktree-provision: lib/glob-regex.sh missing" >&2; exit 1; }

# --- the dependency-directory map ----------------------------------------------
# Which dependency directories this script may link, and which lockfiles pin
# each. Data, so another stack is one more entry; the Stop hook knows none of
# it and compares the record instead.
# An isolation.provision.symlink entry is a string ("vendor") or an object
# ({"path": "vendor", "lockfiles": ["composer.lock"]}). An object with
# "lockfiles" names the files that pin that tree, repo-relative, globs allowed
# (a * stays within one directory, as in the shell); "lockfiles": [] declares
# it unguarded. A string, or an object without a usable "lockfiles", takes the
# lockfiles of a well-known dependency directory from dep_lockfiles below and
# matches them both beside the project that owns the entry and at the repo
# root (a nested apps/web/node_modules is pinned by either). Anything else (an
# .env file, a cache) is unguarded: it pins no dependency set, and guarding it
# would skip every link of one.
# DEP_DIRS entries are repo-relative; a * stays within one directory and is
# expanded against the checkout root (vendor-bin/*/vendor: the per-tool vendor
# trees the Composer bin plugin installs).
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
    while IFS= read -r match; do
      [ -n "$match" ] || continue
      if [ "$mode" = "-" ]; then
        infer_entry "$match"
      elif [ "$rest" = "=" ]; then
        printf '%s\n' "$match"
      else
        printf '%s\t%s\n' "$match" "${rest#=$'\t'}"
      fi
    done < <(expand_entry "$path")
  done <<< "$raw"
}

# expand_entry <path> -> the path itself, or for a glob (vendor-bin/*/vendor,
# the Composer bin plugin's layout) each match in the main checkout, a *
# staying within one directory. A glob with no match prints itself, so the
# caller can say so.
expand_entry() {
  case "$1" in
    *[*?[]*) ;;
    *) printf '%s\n' "$1"; return ;;
  esac
  # The glob is meant to expand; IFS is empty, so nothing splits.
  local IFS='' found=0 match
  while IFS= read -r match; do
    [ -n "$match" ] || continue
    printf '%s\n' "$match"
    found=1
  done < <(cd "$MAIN" 2>/dev/null && shopt -s nullglob && for m in $1; do printf '%s\n' "$m"; done)
  [ "$found" -eq 1 ] || printf '%s\n' "$1"
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
# thousands of links costs no fork per link. A tree the scan cannot list
# counts as loading: one whose root, or a NESTED_LINK_DIRS entry, cannot be
# read (mode 0311 lets cd in but lists nothing), and any tree under a find
# that cannot run the scan (one without -mindepth, say). An unscanned tree is
# never accepted; TLC_UNLISTED names the directory that could not be listed,
# for the caller's message. Past those probes the scan's own exit status is
# ignored: find also fails on an unreadable directory deeper in the tree,
# after listing every link it could read, and that failure says nothing
# about those links.
# NESTED_LINK_DIRS are tree-relative directories that hold links of their
# own one or two levels down, such as the pnpm hidden hoist
# (.pnpm/node_modules/@scope/<name>, four levels below the tree). Data, so
# another layout is one more entry.
NESTED_LINK_DIRS=".pnpm/node_modules"
tree_loads_checkout() {
  local tree="$1" checkout="$2" f url dir real links nested
  local -a nests
  TLC_UNLISTED=""
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
  # Lists the root's own entries only, so an unreadable directory one level
  # down does not trip it.
  find "$real" -mindepth 1 -maxdepth 1 >/dev/null 2>&1 || { TLC_UNLISTED="$tree"; return 0; }
  links=$(find "$real" -mindepth 1 -maxdepth 2 -type l 2>/dev/null || true)
  read -ra nests <<< "$NESTED_LINK_DIRS"
  for nested in ${nests[@]+"${nests[@]}"}; do
    [ -d "$real/$nested" ] || continue
    find "$real/$nested" -mindepth 1 -maxdepth 1 >/dev/null 2>&1 || { TLC_UNLISTED="$tree/$nested"; return 0; }
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

# is_dep_dir <entry> -> 0 when the entry is a DEP_DIRS tree, at the root or
# nested (apps/web/node_modules).
is_dep_dir() {
  local p
  local -a deps
  read -ra deps <<< "$DEP_DIRS"
  for p in "${deps[@]}"; do
    # shellcheck disable=SC2254 # $p is a pattern on purpose (vendor-bin/*/vendor)
    case "$1" in $p|*/$p) return 0 ;; esac
  done
  return 1
}

# clone_tree <src> <dst> -> a copy-on-write clone where the filesystem has
# one; returns 1, leaving nothing at <dst>, when neither clone flag works.
# GNU cp's --reflink=auto copies plainly where it cannot clone. /bin/cp, not
# cp: `cp` is shadowed by a shell alias in some environments.
clone_tree() {
  /bin/cp --reflink=auto -pR "$1" "$2" 2>/dev/null && return 0
  rm -rf "$2"
  /bin/cp -c -pR "$1" "$2" 2>/dev/null && return 0
  rm -rf "$2"
  return 1
}

# clone_into <src dir> <dst dir> -> clones the contents of <src dir> into the
# existing <dst dir> (a placeholder directory being filled), the same two
# clone flags as clone_tree. Returns 1 when neither works; what a failed
# attempt left is overwritten by the plain copy that follows.
clone_into() {
  /bin/cp --reflink=auto -pR "$1/." "$2/" 2>/dev/null && return 0
  /bin/cp -c -pR "$1/." "$2/" 2>/dev/null && return 0
  return 1
}

# repo_relative <path> -> 0 when the path stays inside the checkout.
repo_relative() {
  case "/$1/" in
    //*|*/../*) return 1 ;;
  esac
  [ "${1#/}" = "$1" ]
}

# lock_paths <dir> <pattern>... -> the repo-relative paths under checkout
# <dir> that the lockfile patterns match (a * stays within one directory).
lock_paths() {
  local dir="$1" pat f
  shift
  for pat in "$@"; do
    for f in "$dir"/$pat; do
      [ -f "$f" ] && printf '%s\n' "${f#"$dir"/}"
    done
  done
}

# lockfile_diff <pattern>... -> prints the first lockfile whose copies in the
# worktree and the main checkout differ (one missing on either side counts),
# and returns 0; returns 1 when every copy matches.
lockfile_diff() {
  local rel
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    cmp -s "$WORKTREE/$rel" "$MAIN/$rel" && continue
    printf '%s\n' "$rel"
    return 0
  done < <({ lock_paths "$WORKTREE" "$@"; lock_paths "$MAIN" "$@"; } | sort -u)
  return 1
}

# Sourced (the tests call tree_loads_checkout directly): the functions only.
(return 0 2>/dev/null) && return 0

WORKTREE=""
BASE=""
MAIN=""
NO_SYMLINK=0
NO_INSTALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="${2:-}"; shift 2 ;;
    --main) MAIN="${2:-}"; shift 2 ;;
    --no-symlink) NO_SYMLINK=1; shift ;;
    --no-install) NO_INSTALL=1; shift ;;
    -*) echo "worktree-provision: unknown argument '$1'" >&2; exit 1 ;;
    *) WORKTREE="$1"; shift ;;
  esac
done

if [ -z "$WORKTREE" ] || [ ! -d "$WORKTREE" ]; then
  echo "usage: worktree-provision.sh <worktree-path> [--base <ref>] [--main <path>] [--no-symlink] [--no-install]" >&2
  exit 1
fi

WORKTREE=$(physical_dir "$WORKTREE")

if [ -z "$MAIN" ] && checkout_facts "$WORKTREE"; then
  MAIN="$CF_MAIN"
fi

if [ -z "$MAIN" ] || [ ! -d "$MAIN" ]; then
  echo "worktree-provision: cannot resolve the main checkout — pass --main <path>" >&2
  exit 1
fi

if [ "$MAIN" = "$WORKTREE" ]; then
  echo "worktree-provision: '$WORKTREE' is the main checkout, not a linked worktree" >&2
  exit 1
fi


# Settings, through the one reader. Without jq the defaults apply, as before.
SETTINGS_ROOT="$MAIN"
[ -f "$WORKTREE/.myspec.json" ] && SETTINGS_ROOT="$WORKTREE"
HAVE_JQ=1
command -v jq >/dev/null 2>&1 || HAVE_JQ=0
setting() {
  bash "$HERE/myspec-config.sh" get "$1" --root "$SETTINGS_ROOT" \
    || { echo "worktree-provision: cannot read $1 (is $HERE/myspec-config.sh installed?)" >&2; exit 1; }
}

SYMLINK_CFG=$(mktemp)
trap 'rm -f "$SYMLINK_CFG"' EXIT
COPY_LINES=$'.eslintcache\tcopy'
CLEAN_GLOBS=""
INSTALL_STEPS=""
if [ "$HAVE_JQ" -eq 1 ]; then
  jq -n --argjson s "$(setting isolation.provision.symlink)" '{isolation: {provision: {symlink: $s}}}' > "$SYMLINK_CFG"
  COPY_LINES=$(setting isolation.provision.copy | jq -r '.[]
    | if type == "string" then [., "copy"]
      elif type == "object" and (.path | type) == "string" then [.path, (.mode // "copy" | tostring)]
      else empty end
    | @tsv')
  CLEAN_GLOBS=$(setting isolation.provision.clean | jq -r '.[] | select(type == "string" and . != "")')
  # One compact JSON step per line; a malformed one is kept, to stop on.
  INSTALL_STEPS=$(setting isolation.provision.install | jq -c '
    if . == null then empty elif type == "string" then {run: .} else .[] end
    | if type == "string" then {run: .} else . end')
else
  rm -f "$SYMLINK_CFG"
  echo "worktree-provision: jq not found — using the default symlink and copy lists; clean and install need jq"
fi

INSTALL_ACTIVE=0
[ -n "$INSTALL_STEPS" ] && [ "$NO_INSTALL" -eq 0 ] && INSTALL_ACTIVE=1

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

# isolation.allowLinkedModules: links are recorded without lockfile hashes
# and the lockfile comparison is skipped (see the header).
ALLOW_LINKED=false
[ "$HAVE_JQ" -eq 0 ] || ALLOW_LINKED=$(setting isolation.allowLinkedModules)

LINKED=0
COPIED=0
CLEANED=0
INSTALLED=0
MAIN_REAL=$(cd "$MAIN" && pwd -P)
RECORD="$WORKTREE/.claude/state/provision.json"
# Copies an earlier run recorded that still exist, one JSON object per line.
PREV_COPIES=""
if [ "$HAVE_JQ" -eq 1 ] && [ -f "$RECORD" ]; then
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    p=$(jq -r '.path' <<< "$c")
    repo_relative "$p" && { [ -e "$WORKTREE/$p" ] || [ -L "$WORKTREE/$p" ]; } && PREV_COPIES="$PREV_COPIES$c"$'\n'
  done < <(jq -c '.copies[]? | select(type == "object" and (.path | type) == "string")' "$RECORD" 2>/dev/null || true)
fi
# One compact JSON object per line, for the record.
REC_LINKS=""
REC_COPIES=""
REC_INSTALL=""

# write_record -> <worktree>/.claude/state/provision.json from what this run
# did (the header gives the shape). A copy an earlier run made is kept while
# it exists. Needs jq; without it no record is written, and the Stop hook
# then compares nothing.
write_record() {
  [ "$HAVE_JQ" -eq 1 ] || return 0
  mkdir -p "$(dirname "$RECORD")"
  {
    printf '%s' "$REC_LINKS" | jq -sc '.'
    printf '%s' "$REC_COPIES" | jq -sc '.'
    printf '%s' "$REC_INSTALL" | jq -sc '.'
    printf '%s' "$PREV_COPIES" | jq -sc '.'
  } | jq -s --arg src "$MAIN_REAL" --argjson at "$(date +%s)" '
    .[1] as $new
    | {provisionedAt: $at, source: $src, links: .[0],
       copies: ($new + [.[3][] | select(.path as $p | $new | any(.[]; .path == $p) | not)]),
       install: .[2]}' > "$RECORD.tmp"
  mv "$RECORD.tmp" "$RECORD"
  exclude ".claude/state/provision.json"
}

# --- 1. symlink ---------------------------------------------------------------
PLACEHOLDERS=()
while IFS= read -r line; do
  [ -n "$line" ] || continue
  entry="${line%%$'\t'*}"
  LOCKS=()
  SPECS=()
  if [ "$line" != "$entry" ]; then
    IFS=$'\t' read -ra LOCKS <<< "${line#*$'\t'}"
    # :(glob) keeps a * inside one directory, as the shell glob in lock_paths does.
    for lock in "${LOCKS[@]}"; do SPECS+=(":(glob)$lock"); done
  fi
  # A glob comes back unexpanded only when nothing in the main checkout matched.
  case "$entry" in
    *[*?[]*)
      if [ ! -e "$MAIN/$entry" ]; then
        echo "worktree-provision: no match for $entry in the main checkout — nothing linked for it"
        continue
      fi ;;
  esac
  # A link an earlier run made is decided again, so a rerun after a lockfile
  # change drops a link that no longer matches and records the one that does.
  # Compared physically: an earlier run may have got --main through a symlink
  # (a symlinked home, /tmp for /private/tmp) that this run's spelling of the
  # main checkout does not share.
  if [ -L "$WORKTREE/$entry" ] \
      && [ "$(physical_path "$(readlink "$WORKTREE/$entry")" "$(dirname "$WORKTREE/$entry")")" = "$(physical_path "$MAIN_REAL/$entry")" ]; then
    rm -f "$WORKTREE/$entry"
  fi
  # ${arr[@]+"${arr[@]}"}: an empty array is "unbound" under set -u in bash < 4.4
  if [ "$BASE_OK" -eq 1 ] && [ "${#SPECS[@]}" -gt 0 ] \
      && [ -n "$(git -C "$WORKTREE" diff --name-only "$BASE...HEAD" -- ${SPECS[@]+"${SPECS[@]}"} 2>/dev/null)" ]; then
    echo "worktree-provision: lockfile differs from $BASE — not linking $entry; run a real install in the worktree"
    continue
  fi
  if tree_loads_checkout "$MAIN/$entry" "$MAIN_REAL"; then
    if [ -n "$TLC_UNLISTED" ]; then
      echo "worktree-provision: cannot list ${TLC_UNLISTED#"$MAIN"/} in the main checkout — not linking $entry; a tree that cannot be scanned for links into the main checkout is never linked (check its permissions), or run a real install in the worktree"
      continue
    fi
    echo "worktree-provision: $entry loads the main checkout's own source — not linking $entry; set isolation.provision.install or run a real install in the worktree"
    continue
  fi
  if [ "$NO_SYMLINK" -eq 1 ]; then
    echo "worktree-provision: --no-symlink — not linking $entry; run a real install in the worktree"
    continue
  fi
  [ -e "$MAIN/$entry" ] || continue
  if is_dep_dir "$entry" && [ "$INSTALL_ACTIVE" -eq 1 ]; then
    echo "worktree-provision: install is set — not linking $entry; the install steps build it in the worktree"
    continue
  fi
  if [ -e "$WORKTREE/$entry" ] || [ -L "$WORKTREE/$entry" ]; then
    # A directory the branch tracks files in (#239: node_modules/.gitkeep)
    # cannot become a link, and skipping it quietly leaves an empty tree the
    # checks then fail on.
    tracked=""
    if [ -d "$WORKTREE/$entry" ] && [ ! -L "$WORKTREE/$entry" ]; then
      tracked=$(git -C "$WORKTREE" ls-files -- ":(literal)$entry")
    fi
    if [ -n "$tracked" ]; then
      PLACEHOLDERS+=("${tracked%%$'\n'*}")
      echo "worktree-provision: $entry holds a tracked file (${tracked%%$'\n'*}) — cannot link $entry; untrack it (git rm --cached ${tracked%%$'\n'*}, keeping $entry ignored), or move $entry from isolation.provision.symlink to isolation.provision.copy" >&2
    else
      echo "worktree-provision: $entry already exists in the worktree — not linking $entry"
    fi
    continue
  fi
  LOCK_JSON='{}'
  if [ "$ALLOW_LINKED" != "true" ] && [ "${#LOCKS[@]}" -gt 0 ]; then
    if changed=$(lockfile_diff "${LOCKS[@]}"); then
      echo "worktree-provision: $changed differs from the main checkout — not linking $entry; run a real install in the worktree"
      continue
    fi
  fi
  if [ "$ALLOW_LINKED" != "true" ] && [ "${#LOCKS[@]}" -gt 0 ] && [ "$HAVE_JQ" -eq 1 ]; then
    hashed=1
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      if ! sum=$(file_sha256 "$MAIN/$rel"); then
        echo "worktree-provision: cannot hash $rel (no sha256sum, shasum or openssl) — not linking $entry; run a real install in the worktree"
        hashed=0
        break
      fi
      LOCK_JSON=$(jq -c --arg k "$rel" --arg v "$sum" '. + {($k): $v}' <<< "$LOCK_JSON")
    done < <(lock_paths "$MAIN" "${LOCKS[@]}" | sort -u)
    [ "$hashed" -eq 1 ] || continue
    # A pattern that matched nothing, and every glob, is recorded with a null
    # hash, so the gate sees a lockfile that appears later on either side.
    ABSENT=()
    for lock in "${LOCKS[@]}"; do
      case "$lock" in
        *[*?[]*) ABSENT+=("$lock") ;;
        *) [ -n "$(lock_paths "$MAIN" "$lock")" ] || ABSENT+=("$lock") ;;
      esac
    done
    if [ "${#ABSENT[@]}" -gt 0 ]; then
      LOCK_JSON=$(jq -c --args 'reduce $ARGS.positional[] as $k (.; if has($k) then . else . + {($k): null} end)' "${ABSENT[@]}" <<< "$LOCK_JSON")
    fi
  fi
  mkdir -p "$(dirname "$WORKTREE/$entry")"
  ln -s "$MAIN/$entry" "$WORKTREE/$entry"
  exclude "$entry"
  LINKED=$(( LINKED + 1 ))
  if [ "$HAVE_JQ" -eq 1 ]; then
    if [ -d "$MAIN/$entry" ]; then target=$(physical_dir "$MAIN/$entry"); else target=$(physical_path "$MAIN/$entry"); fi
    REC_LINKS="$REC_LINKS$(jq -nc --arg p "$entry" --arg t "$target" --argjson l "$LOCK_JSON" '{path: $p, target: $t, lockfiles: $l}')"$'\n'
  fi
done < <(symlink_entries "$SYMLINK_CFG")

if [ "${#PLACEHOLDERS[@]}" -gt 0 ]; then
  write_record
  echo "worktree-provision: provisioning stopped — the tracked file(s) above keep a directory from being linked: ${PLACEHOLDERS[*]}" >&2
  exit 1
fi

# --- 2. copy ------------------------------------------------------------------
while IFS=$'\t' read -r entry mode; do
  while [ "${entry#./}" != "$entry" ]; do entry="${entry#./}"; done
  entry="${entry%/}"
  [ -n "$entry" ] || continue
  if ! repo_relative "$entry"; then
    echo "worktree-provision: copy entry $entry leaves the checkout — skipped"
    continue
  fi
  [ -e "$MAIN/$entry" ] || continue
  # A directory holding only tracked files (a placeholder, #239) is filled.
  fill=0
  if [ -d "$WORKTREE/$entry" ] && [ ! -L "$WORKTREE/$entry" ] && [ -d "$MAIN/$entry" ] \
      && [ -z "$(git -C "$WORKTREE" ls-files -o -- ":(literal)$entry")" ]; then
    fill=1
  elif [ -e "$WORKTREE/$entry" ] || [ -L "$WORKTREE/$entry" ]; then
    continue
  fi
  mkdir -p "$(dirname "$WORKTREE/$entry")"
  # The record says what was done: clone only where a clone flag worked.
  done_mode=copy
  if [ "$fill" -eq 1 ]; then
    if [ "$mode" = clone ] && clone_into "$MAIN/$entry" "$WORKTREE/$entry"; then
      done_mode=clone
      echo "worktree-provision: filled $entry by clone, which held only tracked files"
    else
      /bin/cp -pR "$MAIN/$entry/." "$WORKTREE/$entry/"
      [ "$mode" != clone ] || echo "worktree-provision: no copy-on-write clone on this filesystem — copied $entry"
      echo "worktree-provision: filled $entry, which held only tracked files"
    fi
  else
    case "$mode" in
      clone)
        if clone_tree "$MAIN/$entry" "$WORKTREE/$entry"; then
          done_mode=clone
          echo "worktree-provision: cloned $entry"
        else
          /bin/cp -pR "$MAIN/$entry" "$WORKTREE/$entry"
          echo "worktree-provision: no copy-on-write clone on this filesystem — copied $entry"
        fi
        ;;
      *)
        [ "$mode" = "copy" ] || echo "worktree-provision: unknown copy mode '$mode' for $entry — copying it"
        /bin/cp -pR "$MAIN/$entry" "$WORKTREE/$entry"
        ;;
    esac
  fi
  exclude "$entry"
  COPIED=$(( COPIED + 1 ))
  if [ "$HAVE_JQ" -eq 1 ]; then
    REC_COPIES="$REC_COPIES$(jq -nc --arg p "$entry" --arg m "$done_mode" '{path: $p, mode: $m}')"$'\n'
  fi
done <<< "$COPY_LINES"

# --- 3. clean -----------------------------------------------------------------
REGEXES=()
while IFS= read -r glob; do
  [ -n "$glob" ] || continue
  if ! re=$(glob_regex "$glob"); then
    echo "worktree-provision: clean glob $glob leaves the checkout — skipped"
    continue
  fi
  REGEXES+=("$re")
done <<< "$CLEAN_GLOBS"
if [ "${#REGEXES[@]}" -gt 0 ]; then
  REMOVED=""
  # Links are pruned, never printed: a clean never deletes a link or through one.
  while IFS= read -r -d '' path; do
    rel="${path#"$WORKTREE"/}"
    [ -n "$REMOVED" ] && case "$rel/" in "$REMOVED"/*) continue ;; esac
    for re in "${REGEXES[@]}"; do
      [[ "$rel" =~ $re ]] || continue
      if [ -n "$(git -C "$WORKTREE" ls-files -- ":(literal)$rel")" ]; then
        echo "worktree-provision: not cleaning $rel — it is tracked"
      else
        rm -rf "$path"
        CLEANED=$(( CLEANED + 1 ))
        REMOVED="$rel"
      fi
      break
    done
  done < <(find "$WORKTREE" -mindepth 1 \( -path "$WORKTREE/.git" -o -type l \) -prune -o -print0 2>/dev/null)
fi

# The links and copies are recorded before any install step runs, so a
# failing step still leaves them on record.
write_record

# --- 4. install ---------------------------------------------------------------
N=0
while IFS= read -r step; do
  [ -n "$step" ] || continue
  N=$(( N + 1 ))
  if ! printf '%s' "$step" | jq -e 'type == "object" and (.run | type) == "string" and .run != ""
      and ((.cwd // ".") | type) == "string"
      and ((.when // []) | type == "string" or (type == "array" and all(.[]; type == "string")))' >/dev/null; then
    echo "worktree-provision: install step $N is malformed: $step — needs {\"run\": \"<command>\", \"cwd\": \"<dir>\", \"when\": [\"<path>\"]}; provisioning stopped" >&2
    exit 1
  fi
  run=$(printf '%s' "$step" | jq -r '.run')
  cwd=$(printf '%s' "$step" | jq -r '.cwd // "." | if . == "" then "." else . end')
  if [ "$NO_INSTALL" -eq 1 ]; then
    echo "worktree-provision: --no-install — skipped install step $N in $cwd: $run"
    continue
  fi
  missing=""
  while IFS= read -r need; do
    [ -n "$need" ] || continue
    if ! repo_relative "$need" || [ ! -e "$WORKTREE/$need" ]; then missing="$need"; break; fi
  done < <(printf '%s' "$step" | jq -r '.when // [] | if type == "string" then . else .[] end')
  if [ -n "$missing" ]; then
    echo "worktree-provision: $missing not found — skipped install step $N: $run"
    continue
  fi
  if ! repo_relative "$cwd" || [ ! -d "$WORKTREE/$cwd" ]; then
    echo "worktree-provision: install step $N cwd $cwd is not a directory in the worktree; provisioning stopped" >&2
    exit 1
  fi
  echo "worktree-provision: install step $N in $cwd: $run"
  status=0
  (
    cd "$WORKTREE/$cwd"
    export MYSPEC_WORKTREE="$WORKTREE" MYSPEC_MAIN_CHECKOUT="$MAIN"
    # The loop reads the step list on stdin; a step must not inherit it.
    bash -c "$run" </dev/null
  ) || status=$?
  if [ "$status" -ne 0 ]; then
    echo "worktree-provision: install step $N failed (exit $status) in $cwd: $run — provisioning stopped; fix the step and rerun, or rerun with --no-install and install by hand" >&2
    exit 1
  fi
  INSTALLED=$(( INSTALLED + 1 ))
  REC_INSTALL="$REC_INSTALL$(jq -nc --arg r "$run" --arg c "$cwd" '{run: $r, cwd: $c}')"$'\n'
done <<< "$INSTALL_STEPS"

write_record

echo "worktree-provision: $LINKED symlinked, $COPIED copied, $CLEANED cleaned, $INSTALLED installed into $WORKTREE"
