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
# hashing every one of them at every Bash call would cost more than the
# writes it finds. Its writes are the command scanner's alone.
STATUS_DIFF_MAX=${STATUS_DIFF_MAX:-2000}

# status_entries <root> -> the changed and untracked files of the checkout,
# one NUL-terminated repo-relative path each, sorted: tracked files that
# differ from HEAD or the index, deletions included, and untracked files
# that are not ignored. A submodule or a nested repository is left out.
# The caller has checked that <root> is a work tree (status_head).
status_entries() {
  GIT_OPTIONAL_LOCKS=0 git -C "$1" status --porcelain -z --untracked-files=all \
    --no-renames --ignore-submodules=all 2>/dev/null \
    | jq -Rsrj 'split("\u0000") | map(select(length > 3) | .[3:] | select(endswith("/") | not))
        | unique | map(. + "\u0000") | add // ""' 2>/dev/null || true
}

# status_head <root> -> HEAD's commit id ("" on an unborn branch); fails
# when git cannot read <root> as a work tree. One git call.
status_head() {
  local out
  out=$(GIT_OPTIONAL_LOCKS=0 git -C "$1" rev-parse --is-inside-work-tree -q --verify HEAD 2>/dev/null) || true
  [ "${out%%$'\n'*}" = true ] || return 1
  case "$out" in
    *$'\n'*) printf '%s\n' "${out#*$'\n'}" ;;
    *) printf '\n' ;;
  esac
}

# status_hash <root> <write: 0|1> <rel>... -> one line per path: the blob id
# of the file as it is now, "-" when there is no file, "d" when it is not a
# regular file. With write=1 the blobs go to the object store (the content
# checks read them later). One git call for every path without a newline in
# it; such a path, rare as it is, is hashed alone.
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

# status_capture <root> [keep function] -> the checkout's state before a
# Bash call, NUL-separated: <root>, HEAD's commit id ("" on an unborn branch), then
# "1" when the tree was too dirty to capture (STATUS_DIFF_MAX) else "0",
# then a path and its status_hash per changed file. <keep function>, called
# as `<fn> <root> <rel>`, names the files whose blobs are written to the
# object store: the before side of a content check. Fails when git cannot
# read the checkout.
status_capture() {
  local root="$1" keep="${2:-}" head rel n=0 h
  local -a rels=() kept=() plain=() hashes=()
  head=$(status_head "$root") || return 1
  while IFS= read -r -d '' rel; do
    rels+=("$rel")
    n=$((n + 1))
  done < <(status_entries "$root")
  if [ "$n" -gt "$STATUS_DIFF_MAX" ]; then
    printf '%s\0%s\0%s\0' "$root" "$head" 1
    return 0
  fi
  printf '%s\0%s\0%s\0' "$root" "$head" 0
  [ "$n" -gt 0 ] || return 0
  for rel in "${rels[@]}"; do
    if [ -n "$keep" ] && "$keep" "$root" "$rel"; then kept+=("$rel"); else plain+=("$rel"); fi
  done
  if [ "${#kept[@]}" -gt 0 ]; then
    while IFS= read -r h; do hashes+=("$h"); done < <(status_hash "$root" 1 "${kept[@]}")
    for ((n = 0; n < ${#kept[@]}; n++)); do printf '%s\0%s\0' "${kept[$n]}" "${hashes[$n]:-d}"; done
  fi
  hashes=()
  if [ "${#plain[@]}" -gt 0 ]; then
    while IFS= read -r h; do hashes+=("$h"); done < <(status_hash "$root" 0 "${plain[@]}")
    for ((n = 0; n < ${#plain[@]}; n++)); do printf '%s\0%s\0' "${plain[$n]}" "${hashes[$n]:-d}"; done
  fi
}

# status_changes <capture file> -> the files the call wrote in the capture's
# checkout, as NUL-separated pairs: the repo-relative path and its content before the
# call (a blob id, or "-" when there was no file). A file is written when it
# is changed or untracked now and was not before, or was before and its
# content differs now (a revert to HEAD, a deletion included). A file whose
# content is what it was is not, whatever its status did (`git add`, a
# commit). Fails when the capture is missing or was too dirty to take, or
# when git cannot read the checkout: the caller then has only the command
# scanner. The before of a file that was clean is HEAD's blob at capture
# time ("-" when HEAD did not have it).
status_changes() {
  local cap="$1" root head capped rel h kind i
  local -a pre=() now=() chk=() chk_before=() hashes=() clean=()
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
  status_head "$root" >/dev/null || return 1
  while IFS= read -r -d '' rel; do
    now+=("$rel")
  done < <(status_entries "$root")
  # Which files need a look: jq sorts it out, so a dirty tree costs one
  # process, not a scan per file. Its arguments: the number of capture
  # fields, the capture's path/hash pairs, the paths changed now (a count,
  # not a separator: bash 3.2 doubles a \001 argument). Out come
  # NUL-separated triples: "new" (changed now, clean before) or "chk"
  # (changed before: compare the content), the path, the hash before.
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
    while IFS= read -r h; do hashes+=("$h"); done < <(status_hash "$root" 0 "${chk[@]}")
    for ((i = 0; i < ${#chk[@]}; i++)); do
      [ "${chk_before[$i]}" != d ] || continue
      [ "${hashes[$i]:-}" != "${chk_before[$i]}" ] || continue
      printf '%s\0%s\0' "${chk[$i]}" "${chk_before[$i]}"
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
