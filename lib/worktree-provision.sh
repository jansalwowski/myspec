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
#      main checkout and is absent in the worktree, and lists it in the
#      worktree's info/exclude so it is never staged. An entry is SKIPPED
#      - when the branch changes one of the lockfiles that pin it relative
#        to --base: a linked tree then describes the wrong dependencies
#        (which lockfiles pin which entry is the dependency-lockfile map);
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
#        would write into the main checkout.
#   2. copy: copies each entry (default: .eslintcache), a file or a
#      directory (#222), for anything a build writes to. {"path": "vendor",
#      "mode": "clone"} makes a copy-on-write clone where the filesystem
#      supports one (--reflink=auto on Btrfs/XFS, cp -c on APFS) and falls
#      back to a plain copy.
#   3. clean: deletes the untracked files and directories in the worktree
#      that match a repo-relative glob (#193), e.g. **/*.tsbuildinfo, so the
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
# The Stop hook accepts a symlinked dependency directory only when the
# lockfiles that pin it are byte-identical to the checkout the link points
# into (the case this script links), unless `.myspec.json` sets
# isolation.allowLinkedModules: true (or the session sets
# MYSPEC_ALLOW_LINKED_MODULES=1). A tree `install` built is a real directory
# and passes as is.
# Recipe: skills/_shared/worktree-provisioning.md

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
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
# END dependency-lockfile map

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

# glob_regex <glob> -> an anchored ERE: ** crosses directories, * and ? stay
# within one, everything else is literal.
glob_regex() {
  local g="$1" re="" c i=0
  while [ "$i" -lt "${#g}" ]; do
    c="${g:$i:1}"
    if [ "$c" = "*" ] && [ "${g:$i:3}" = "**/" ]; then re="$re(.*/)?"; i=$((i + 3)); continue; fi
    if [ "$c" = "*" ] && [ "${g:$i:2}" = "**" ]; then re="$re.*"; i=$((i + 2)); continue; fi
    case "$c" in
      "*") re="${re}[^/]*" ;;
      "?") re="${re}[^/]" ;;
      # The ERE metacharacters, one quoted literal each: a bracket
      # expression here matched none of them on bash 3.2 or 5.
      "."|"["|"\\"|"("|")"|"+"|"{"|"|"|"^"|'$') re="$re\\$c" ;;
      *) re="$re$c" ;;
    esac
    i=$((i + 1))
  done
  printf '^%s$\n' "$re"
}

# repo_relative <path> -> 0 when the path stays inside the checkout.
repo_relative() {
  case "/$1/" in
    //*|*/../*) return 1 ;;
  esac
  [ "${1#/}" = "$1" ]
}

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

LINKED=0
COPIED=0
CLEANED=0
INSTALLED=0
MAIN_REAL=$(cd "$MAIN" && pwd -P)

# --- 1. symlink ---------------------------------------------------------------
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
    echo "worktree-provision: $entry loads the main checkout's own source — not linking $entry; set isolation.provision.install or run a real install in the worktree"
    continue
  fi
  if [ "$NO_SYMLINK" -eq 1 ]; then
    echo "worktree-provision: --no-symlink — not linking $entry; run a real install in the worktree"
    continue
  fi
  if [ -e "$MAIN/$entry" ] && [ ! -e "$WORKTREE/$entry" ]; then
    if is_dep_dir "$entry" && [ "$INSTALL_ACTIVE" -eq 1 ]; then
      echo "worktree-provision: install is set — not linking $entry; the install steps build it in the worktree"
      continue
    fi
    mkdir -p "$(dirname "$WORKTREE/$entry")"
    ln -s "$MAIN/$entry" "$WORKTREE/$entry"
    exclude "$entry"
    LINKED=$(( LINKED + 1 ))
  fi
done < <(symlink_entries "$SYMLINK_CFG")

# --- 2. copy ------------------------------------------------------------------
while IFS=$'\t' read -r entry mode; do
  while [ "${entry#./}" != "$entry" ]; do entry="${entry#./}"; done
  entry="${entry%/}"
  [ -n "$entry" ] || continue
  if ! repo_relative "$entry"; then
    echo "worktree-provision: copy entry $entry leaves the checkout — skipped"
    continue
  fi
  if [ ! -e "$MAIN/$entry" ] || [ -e "$WORKTREE/$entry" ]; then continue; fi
  mkdir -p "$(dirname "$WORKTREE/$entry")"
  case "$mode" in
    clone)
      if clone_tree "$MAIN/$entry" "$WORKTREE/$entry"; then
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
  exclude "$entry"
  COPIED=$(( COPIED + 1 ))
done <<< "$COPY_LINES"

# --- 3. clean -----------------------------------------------------------------
REGEXES=()
while IFS= read -r glob; do
  [ -n "$glob" ] || continue
  if ! repo_relative "$glob"; then
    echo "worktree-provision: clean glob $glob leaves the checkout — skipped"
    continue
  fi
  REGEXES+=("$(glob_regex "${glob#./}")")
done <<< "$CLEAN_GLOBS"
if [ "${#REGEXES[@]}" -gt 0 ]; then
  REMOVED=""
  # Links are pruned, never printed: a clean never deletes a link or through one.
  while IFS= read -r -d '' path; do
    rel="${path#"$WORKTREE"/}"
    [ -n "$REMOVED" ] && case "$rel/" in "$REMOVED"/*) continue ;; esac
    for re in "${REGEXES[@]}"; do
      [[ "$rel" =~ $re ]] || continue
      if [ -n "$(git -C "$WORKTREE" ls-files -- ":(literal)$rel" | head -n 1)" ]; then
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
done <<< "$INSTALL_STEPS"

echo "worktree-provision: $LINKED symlinked, $COPIED copied, $CLEANED cleaned, $INSTALLED installed into $WORKTREE"
