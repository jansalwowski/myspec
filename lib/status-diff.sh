#!/usr/bin/env bash
# status-diff.sh
# Sourced, never run (after lib/hook-core.sh). What a Bash call wrote in a
# checkout, read from git rather than from the command text (#276): the
# working tree's changes before the call (status_capture, at PreToolUse) and
# after it (status_changes, at PostToolUse or PostToolUseFailure). A variable
# path (`f=docs/a.md; printf x >> "$f"`) or a file an interpreter opens
# (`python3 -c "open(...)"`) leaves no trace a command scanner can read, but
# it does change `git status`. Used by hooks/mark-code-changed.sh; tests:
# lib/tests/status-diff.test.sh. docs/stop-gate.md R4 and R14 hold the
# decisions: what is out of reach (gitignored files, a checkout the command
# reaches through a variable `cd`) and what happens when another session
# writes in the same checkout at the same time.
#
# git runs with GIT_OPTIONAL_LOCKS=0: `git status` would otherwise refresh
# and rewrite the index under index.lock, and a `git commit` another session
# starts at that moment would fail on the lock.
#
# bash 3.2 compatible (macOS /bin/bash). jq 1.6 or later.

# A tree with more changed and untracked files than this is not captured:
# a stat (and, for covered files, a hash) of every one of them at every Bash
# call would cost more than the writes it finds. Its writes are the command scanner's alone.
STATUS_DIFF_MAX=${STATUS_DIFF_MAX:-2000}

# status_read <root> -> sets ST_HEAD to HEAD's commit id ("" on an unborn
# branch) and ST_RELS to the changed and untracked files of the checkout,
# repo-relative: tracked files that differ from HEAD or the index,
# deletions and conflicts included, and untracked files that are not
# ignored. A submodule or a nested repository is left out. One `git status
# --porcelain=v2 --branch` call, read here: each process costs a Bash call
# milliseconds, twice. Fails when git cannot read <root> as a work tree (no
# branch header). Runs in the caller's shell, so the caller must not read it
# through a subshell.
ST_HEAD=""
ST_RELS=()
status_read() {
  local rec n i ok=1
  ST_HEAD=""
  ST_RELS=()
  while IFS= read -r -d '' rec; do
    case "$rec" in
      '# branch.oid '*)
        ok=0
        ST_HEAD="${rec#'# branch.oid '}"
        [ "$ST_HEAD" != '(initial)' ] || ST_HEAD=""
        continue
        ;;
      '1 '*) n=8 ;;
      'u '*) n=10 ;;
      '? '*) n=1 ;;
      *) continue ;;
    esac
    # The fields before the path are fixed in number, so a path with a
    # space keeps it.
    for ((i = 0; i < n; i++)); do rec="${rec#* }"; done
    case "$rec" in */) continue ;; esac
    ST_RELS+=("$rec")
  done < <(GIT_OPTIONAL_LOCKS=0 git -C "$1" status --porcelain=v2 -z --branch --untracked-files=all \
    --no-renames --ignore-submodules=all 2>/dev/null || true)
  return "$ok"
}

# status_hash <root> <write: 0|1> <rel>... -> one line per path: the blob id
# of the file as it is now, "-" when there is no file, "d" when it is not a
# regular file. With write=1 the blobs go to the object store (the content
# checks read them later). One git call for every path without a newline in
# it; such a path, rare as it is, is hashed alone. Reads every byte of every
# file: only the keep set (status_capture) and the stat fallback use it.
status_hash() {
  local root="$1" w="$2" rel id one=0
  local -a args=() ids=()
  shift 2
  [ "$w" = 0 ] || args=(-w)
  for rel in "$@"; do
    case "$rel" in *$'\n'*) one=1 ;; esac
  done
  if [ "$one" = 0 ]; then
    while IFS= read -r id; do
      ids+=("$id")
    done < <(for rel in "$@"; do [ -f "$root/$rel" ] && [ ! -L "$root/$rel" ] && printf '%s\n' "$rel"; done \
      | git -C "$root" hash-object ${args[@]+"${args[@]}"} --stdin-paths 2>/dev/null || true)
  fi
  local i=0
  for rel in "$@"; do
    if [ -L "$root/$rel" ] || { [ -e "$root/$rel" ] && [ ! -f "$root/$rel" ]; }; then
      printf 'd\n'
    elif [ ! -e "$root/$rel" ]; then
      printf -- '-\n'
    elif [ "$one" = 0 ] && [ -n "${ids[$i]:-}" ]; then
      printf '%s\n' "${ids[$i]}"
      i=$((i + 1))
    else
      id=$(git -C "$root" hash-object ${args[@]+"${args[@]}"} -- "$rel" 2>/dev/null) || id=d
      printf '%s\n' "$id"
      [ "$one" = 1 ] || i=$((i + 1))
    fi
  done
}

# The stat call status_stat makes: size, inode, then mtime and ctime with
# their fractional seconds where the file system keeps them. BSD stat on
# macOS and the BSDs (by absolute path there, so GNU coreutils first on PATH
# does not take its place), GNU or busybox stat elsewhere. A test may set it.
if [ -z "${STATUS_STAT+x}" ]; then
  case "${OSTYPE:-}" in
    darwin* | *bsd* | dragonfly*)
      if [ -x /usr/bin/stat ]; then STATUS_STAT=(/usr/bin/stat -f 's:%z:%i:%Fm:%Fc'); else STATUS_STAT=(stat -f 's:%z:%i:%Fm:%Fc'); fi
      ;;
    *) STATUS_STAT=(stat -c 's:%s:%i:%y:%z') ;;
  esac
fi

# status_stat <root> <rel>... -> one line per path, like status_hash but
# with the file's stat signature, "s:<size>:<inode>:<mtime>:<ctime>", in
# place of its blob id: one stat process for every path, and no file is
# read, whatever its size (#305 review: hashing a 500 MB untracked file cost
# 2 s at each Pre and Post). A write changes the signature: it moves mtime
# and ctime, and a replace by rename moves the inode too. When stat gives
# fewer lines than it was given files (a file gone between the test and the
# stat, a stat that does not take this format), the paths are hashed
# instead: slower, and at PostToolUse a file the capture holds only a
# signature for then counts as written.
status_stat() {
  local root="$1" rel line
  local -a out=() reg=()
  shift
  for rel in "$@"; do
    if [ -f "$root/$rel" ] && [ ! -L "$root/$rel" ]; then reg+=("$root/$rel"); fi
  done
  if [ "${#reg[@]}" -gt 0 ]; then
    while IFS= read -r line; do
      out+=("${line// /_}")
    done < <("${STATUS_STAT[@]}" -- "${reg[@]}" 2>/dev/null || true)
    if [ "${#out[@]}" -ne "${#reg[@]}" ]; then
      status_hash "$root" 0 "$@"
      return 0
    fi
  fi
  local i=0
  for rel in "$@"; do
    if [ -L "$root/$rel" ] || { [ -e "$root/$rel" ] && [ ! -f "$root/$rel" ]; }; then
      printf 'd\n'
    elif [ ! -e "$root/$rel" ] || [ "$i" -ge "${#out[@]}" ]; then
      printf -- '-\n'
    else
      printf '%s\n' "${out[$i]}"
      i=$((i + 1))
    fi
  done
}

# A kept file above this many bytes is compared by its stat signature alone,
# like any other file: no blob is written for it at every Bash call. A write
# the status diff finds in it then has no before side from the capture, and
# the content check takes HEAD's content as its baseline (docs/stop-gate.md,
# R14).
STATUS_DIFF_KEEP_MAX_BYTES=${STATUS_DIFF_KEEP_MAX_BYTES:-8388608}

# status_capture <root> [keep function] -> the checkout's state before a
# Bash call, NUL-separated: <root>, HEAD's commit id ("" on an unborn branch), then
# "1" when the tree was too dirty to capture (STATUS_DIFF_MAX) else "0",
# then a path and its state per changed file. The state is the file's stat
# signature (status_stat), "-" (no file) or "d" (not a regular file); for a
# kept file, its blob id, a space, then the signature. <keep function>,
# called as `<fn> <root> <rel>`, names the files whose blobs are written to
# the object store: the before side of a content check. Only those files are
# read, and only up to STATUS_DIFF_KEEP_MAX_BYTES each. Fails when git
# cannot read the checkout.
status_capture() {
  local root="$1" keep="${2:-}" head rel n h size
  local -a rels=() sigs=() kept=() kept_sig=() hashes=()
  status_read "$root" || return 1
  head="$ST_HEAD"
  n=${#ST_RELS[@]}
  [ "$n" -eq 0 ] || rels=("${ST_RELS[@]}")
  if [ "$n" -gt "$STATUS_DIFF_MAX" ]; then
    printf '%s\0%s\0%s\0' "$root" "$head" 1
    return 0
  fi
  printf '%s\0%s\0%s\0' "$root" "$head" 0
  [ "$n" -gt 0 ] || return 0
  while IFS= read -r h; do sigs+=("$h"); done < <(status_stat "$root" "${rels[@]}")
  for ((n = 0; n < ${#rels[@]}; n++)); do
    rel="${rels[$n]}" h="${sigs[$n]:-d}"
    case "$h" in
      d | -) ;;
      s:*)
        size="${h#s:}"
        size="${size%%:*}"
        if [ -n "$keep" ] && [ "$size" -le "$STATUS_DIFF_KEEP_MAX_BYTES" ] 2>/dev/null \
            && "$keep" "$root" "$rel"; then
          kept+=("$rel")
          kept_sig+=("$h")
          continue
        fi
        ;;
      *)
        # status_stat fell back to hashing: a kept file still needs its
        # blob in the object store.
        if [ -n "$keep" ] && "$keep" "$root" "$rel"; then
          kept+=("$rel")
          kept_sig+=("")
          continue
        fi
        ;;
    esac
    printf '%s\0%s\0' "$rel" "$h"
  done
  [ "${#kept[@]}" -gt 0 ] || return 0
  while IFS= read -r h; do hashes+=("$h"); done < <(status_hash "$root" 1 "${kept[@]}")
  for ((n = 0; n < ${#kept[@]}; n++)); do
    h="${hashes[$n]:-d}"
    case "$h" in
      d | -) printf '%s\0%s\0' "${kept[$n]}" "$h" ;;
      *) printf '%s\0%s\0' "${kept[$n]}" "$h${kept_sig[$n]:+ ${kept_sig[$n]}}" ;;
    esac
  done
}

# status_changes <capture file> -> the files the call wrote in the capture's
# checkout, as NUL-separated pairs: the repo-relative path and its content
# before the call: a blob id, "-" when there was no file, or "" when the
# capture holds no blob for it (a file dirty before the call that was not
# kept, or was above STATUS_DIFF_KEEP_MAX_BYTES). A file is written when it
# is changed or untracked now and was not before, or was before and its
# stat signature differs now (a revert to HEAD, a deletion included). A kept
# file whose signature moved is hashed: if its content is what it was, it
# was not written. Any other file is not read, so rewriting it with the same
# content (`touch`) counts as a write. A file whose status alone moved (`git
# add`, a commit) is not written. Fails when the capture is missing or was
# too dirty to take, or when git cannot read the checkout: the caller then
# has only the command scanner. The before of a file that was clean is
# HEAD's blob at capture time ("-" when HEAD did not have it).
status_changes() {
  local cap="$1" root head capped rel h kind i id sig
  local -a pre=() now=() chk=() chk_before=() sigs=() clean=() kept=() kept_id=() hashes=()
  [ -f "$cap" ] || return 1
  {
    IFS= read -r -d '' root || return 1
    IFS= read -r -d '' head || return 1
    IFS= read -r -d '' capped || return 1
    while IFS= read -r -d '' rel && IFS= read -r -d '' h; do
      pre+=("$rel" "$h")
    done
  } < "$cap"
  [ "$capped" = 0 ] || return 1
  status_read "$root" || return 1
  [ "${#ST_RELS[@]}" -eq 0 ] || now=("${ST_RELS[@]}")
  # Nothing changed before: every file changed now is new, with no jq.
  # Nothing either side: nothing written (the usual Bash call).
  if [ "${#pre[@]}" -eq 0 ]; then
    [ "${#now[@]}" -gt 0 ] || return 0
    status_head_blobs "$root" "$head" "${now[@]}"
    return 0
  fi
  # Which files need a look: jq sorts it out, so a dirty tree costs one
  # process, not a scan per file. Its arguments: the number of capture
  # fields, the capture's path/state pairs, the paths changed now (a count,
  # not a separator: bash 3.2 doubles a \001 argument). Out come
  # NUL-separated triples: "new" (changed now, clean before) or "chk"
  # (changed before: compare the state), the path, the state before.
  while IFS= read -r -d '' kind && IFS= read -r -d '' rel && IFS= read -r -d '' h; do
    case "$kind" in
      new) clean+=("$rel") ;;
      chk) chk+=("$rel"); chk_before+=("$h") ;;
    esac
  done < <(jq -nj --args '
      ($ARGS.positional[0] | tonumber) as $cut
      | ($ARGS.positional[1:$cut + 1]) as $p
      | ($ARGS.positional[$cut + 1:]) as $n
      | ([range(0; $p | length; 2) as $i | {key: $p[$i], value: $p[$i + 1]}] | from_entries) as $before
      | ([$n[] | select($before[.] == null) | ["new", ., ""]]
         + [$p | range(0; length; 2) as $i | ["chk", $p[$i], $p[$i + 1]]])
      | .[] | map(. + "\u0000") | add' "${#pre[@]}" ${pre[@]+"${pre[@]}"} ${now[@]+"${now[@]}"} 2>/dev/null || true)
  if [ "${#chk[@]}" -gt 0 ]; then
    while IFS= read -r h; do sigs+=("$h"); done < <(status_stat "$root" "${chk[@]}")
    for ((i = 0; i < ${#chk[@]}; i++)); do
      h="${chk_before[$i]}" sig="${sigs[$i]:-d}"
      case "$h" in
        d) continue ;;
        -) [ "$sig" = - ] || printf '%s\0%s\0' "${chk[$i]}" - ;;
        s:*) [ "$sig" = "$h" ] || printf '%s\0%s\0' "${chk[$i]}" "" ;;
        *' 's:*)
          id="${h%% *}"
          [ "$sig" != "${h#* }" ] || continue
          # The stat moved: the content decides, below.
          kept+=("${chk[$i]}")
          kept_id+=("$id")
          ;;
        *)
          # A blob id alone: the stat fallback took it. Hash to compare.
          kept+=("${chk[$i]}")
          kept_id+=("$h")
          ;;
      esac
    done
  fi
  if [ "${#kept[@]}" -gt 0 ]; then
    while IFS= read -r h; do hashes+=("$h"); done < <(status_hash "$root" 0 "${kept[@]}")
    for ((i = 0; i < ${#kept[@]}; i++)); do
      [ "${hashes[$i]:-}" != "${kept_id[$i]}" ] || continue
      printf '%s\0%s\0' "${kept[$i]}" "${kept_id[$i]}"
    done
  fi
  [ "${#clean[@]}" -gt 0 ] || return 0
  status_head_blobs "$root" "$head" "${clean[@]}"
}

# status_head_blobs <root> <commit> <rel>... -> for each path, it and its
# blob in <commit> ("-" when the commit has none, or there is no commit), as
# NUL-separated pairs, from one `git ls-tree`.
status_head_blobs() {
  local root="$1" head="$2" line rel id blobs=$'\034'
  shift 2
  if [ -n "$head" ]; then
    while IFS= read -r -d '' line; do
      id="${line%%$'\t'*}"
      id="${id##* }"
      blobs="$blobs${line#*$'\t'}"$'\035'"$id"$'\034'
    done < <(GIT_OPTIONAL_LOCKS=0 git -C "$root" ls-tree -z --full-tree "$head" -- "$@" 2>/dev/null || true)
  fi
  for rel in "$@"; do
    id="-"
    case "$blobs" in
      *$'\034'"$rel"$'\035'*)
        id="${blobs#*$'\034'"$rel"$'\035'}"
        id="${id%%$'\034'*}"
        ;;
    esac
    printf '%s\0%s\0' "$rel" "$id"
  done
}
