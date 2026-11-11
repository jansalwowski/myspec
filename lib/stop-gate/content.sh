#!/usr/bin/env bash
# stop-gate/content.sh
# lint: sourced under set -euo pipefail
# Sourced by hooks/verify-before-stop.sh, after lib/hook-core.sh,
# lib/session-event.sh, lib/content-checks.sh and stop-gate/arm.sh (arm_init);
# never run. The catch-all for writes the PreToolUse content gates never see
# (#263, docs/stop-gate.md R14): a Bash heredoc, `sed -i`, `tee` and the like
# land without a Write or Edit call, so the three checks run here over the
# lines this session's Bash writes added. Tests:
# lib/tests/stop-gate-content.test.sh, hooks/tests/verify-before-stop-content.test.sh.
#
# Input: the session's Bash writes as before/after blob pairs
# (session_bash_writes; mark-code-changed.sh snapshots a covered file at
# PreToolUse and after the write; a write that removed the file is a pair
# whose after is "-"). Write and Edit calls are not here: their PreToolUse
# hooks judged them. Per file in a checkout of this repository (or nested in
# the cwd's tree) that still exists:
#   - the lines judged are the lines the file gained on net since the
#     session's first Bash write to it (the `+` lines of its earliest
#     before -> the file now) whose text one of the session's Bash writes
#     added (the `+` lines of a before -> after pair). A line the file held
#     before the session, or another session wrote, is not one; nor is a
#     line one write changed and a later one restored (#343). A line this
#     session added and then committed still is;
#   - absolute homedir paths, on those lines, for the files the rule covers
#     (absolute_paths_scope; only those get snapshots);
#   - frontmatter, on a ${aiDir} markdown doc the session created, or whose
#     frontmatter region its writes left different from what they found;
#   - the reuse audit, on a tech-spec the session created.
# "Created" means the file did not exist before the session's first Bash
# write to it (a write that found no file and left none is no write to it),
# so a file removed and restored (`mv` away and back) is not created.
#
# Why both diffs (#343, PR #347 review). The union of the pairs' `+` lines
# alone judged a restored line as added for good, committed or not. The net
# diff alone would sweep in what another session, an Edit or Write call or
# the user changed between two of the session's writes: those changes sit
# between one pair's after and the next pair's before, so no pair adds them,
# and the intersection drops them. Netting each pair's `-` lines against its
# `+` lines by text instead would hide a leak deleted in one place and pasted
# in another. No rule tells that apart from a line moved within the file, so
# a moved line is judged, where the net diff names it.
#
# Each finding blocks the stop with the reason the PreToolUse hook would have
# given. The checks are cheap, and they run inside the gate budget like
# everything else (gate_budget_init runs first). A file whose checks passed is
# not judged again while nothing its verdict read has changed (see "Skipping
# what an earlier Stop judged" below). They block during a
# feature-implement run too: a leaked path is session damage, not an
# expected red, like the conformance gates.

# content_root_ok <root> -> 0 when <root> is a checkout of the cwd's
# repository, or a checkout nested inside the cwd's tree (a submodule, a
# plain clone) whose writes the cwd's gate owns.
content_root_ok() {
  if same_repo "$1"; then
    return 0
  fi
  case "$1/" in
    "$ORIG_ROOT"/*) return 0 ;;
  esac
  return 1
}

# content_root_facts <root> -> sets CONTENT_ROOT_OK (1 when the gates own
# <root>: a directory content_root_ok accepts) and CONTENT_AI (its aiDir,
# empty without a .myspec.json), CONTENT_ROOT_I being the root's index in the
# cache. Asked once per root, not once per file: ai_dir runs the settings
# reader, about 60 ms, which at 50 files was a third of the gate's time.
# Parallel arrays, as bash 3.2 has no associative ones.
CONTENT_ROOTS=() CONTENT_ROOT_OKS=() CONTENT_ROOT_AIS=() CONTENT_ROOT_DEFAULTS=()
CONTENT_ROOT_OK=0 CONTENT_AI="" CONTENT_ROOT_I=0
content_root_facts() {
  CONTENT_ROOT_I=0
  while [ "$CONTENT_ROOT_I" -lt "${#CONTENT_ROOTS[@]}" ]; do
    if [ "${CONTENT_ROOTS[CONTENT_ROOT_I]}" = "$1" ]; then
      CONTENT_ROOT_OK=${CONTENT_ROOT_OKS[CONTENT_ROOT_I]}
      CONTENT_AI=${CONTENT_ROOT_AIS[CONTENT_ROOT_I]}
      return 0
    fi
    CONTENT_ROOT_I=$((CONTENT_ROOT_I + 1))
  done
  CONTENT_ROOT_OK=0 CONTENT_AI=""
  if [ -d "$1" ] && content_root_ok "$1"; then
    CONTENT_ROOT_OK=1
    [ ! -f "$1/.myspec.json" ] || CONTENT_AI=$(ai_dir "$1")
  fi
  CONTENT_ROOTS+=("$1")
  CONTENT_ROOT_OKS+=("$CONTENT_ROOT_OK")
  CONTENT_ROOT_AIS+=("$CONTENT_AI")
  CONTENT_ROOT_DEFAULTS+=("")
}

# content_root_default_ai -> the aiDir a root without a .myspec.json falls
# back to (the schema default, through ai_dir), for the root
# content_root_facts was last asked about. Read on first use, then cached.
content_root_default_ai() {
  if [ -z "${CONTENT_ROOT_DEFAULTS[CONTENT_ROOT_I]}" ]; then
    CONTENT_ROOT_DEFAULTS[CONTENT_ROOT_I]=$(ai_dir "${CONTENT_ROOTS[CONTENT_ROOT_I]}")
  fi
  CONTENT_AI_DEFAULT=${CONTENT_ROOT_DEFAULTS[CONTENT_ROOT_I]}
}

# content_snapshot <root> <snapshot> <out file> -> writes a snapshot's
# content: a blob in <root>'s object store, or for "kept:<id>" the copy
# mark-code-changed.sh kept beside the session file when the store was
# read-only (session_keep). Sets CONTENT_KEPT=1 for a copy: its bytes skipped
# git's line-ending conversion. Reads STATE_HOME, SESSION_ID.
content_snapshot() {
  local copy
  case "$2" in
    kept:*)
      copy=$(session_kept "$STATE_HOME" "$SESSION_ID" "${2#kept:}") || return 1
      CONTENT_KEPT=1
      cat -- "$copy" > "$3" 2>/dev/null
      ;;
    *) git -C "$1" cat-file blob "$2" > "$3" 2>/dev/null ;;
  esac
}

# content_before <root> <rel> <before> <out file> -> writes the file's content
# before a Bash write: the snapshot <before> (content_snapshot); nothing for
# "-" (there was no file); for "?" (no snapshot) or "@" (the previous write
# was neither hashed nor kept) HEAD's version, or nothing when HEAD has none.
# Sets CONTENT_NEW=1 when there was no file.
content_before() {
  CONTENT_NEW=0
  case "$3" in
    -) : > "$4"; CONTENT_NEW=1 ;;
    \?|@)
      if ! git -C "$1" show "HEAD:$2" > "$4" 2>/dev/null; then
        : > "$4"
        CONTENT_NEW=1
      fi
      ;;
    *) content_snapshot "$1" "$3" "$4" || return 1 ;;
  esac
}

# added_lines <old file> <new file> <out file> -> writes `<line>\t<text>` for
# each line of <new file> that is not in <old file>: the `+` lines of
# `git diff --no-index -U0`, numbered from the hunk headers.
added_lines() {
  # The `---`/`+++` header lines precede the first hunk, so only lines after
  # a hunk header count; a line in the body starting with +++ is content.
  git diff --no-index --no-color --no-ext-diff -U0 -- "$1" "$2" 2>/dev/null | LC_ALL=C awk '
    /^@@/ { match($0, /\+[0-9]+/); n = substr($0, RSTART + 1, RLENGTH - 1) + 0; hunk = 1; next }
    hunk && /^\+/ { printf "%d\t%s\n", n, substr($0, 2); n++; next }
    hunk && /^ / { n++ }' > "$3" || true
}

# session_lines <net> <added> <out file> -> writes the <net> lines (the file's
# own `<n>\t<text>` lines it gained since the session's first write, as
# added_lines writes them) whose text is one of the <added> lines (every
# pair's added_lines): what the session added that the file still holds.
# A trailing CR is dropped on both sides: the blobs went through git's
# line-ending conversion (core.autocrlf, `text eol=crlf`), the working file
# did not, so a CRLF line would otherwise never match its added text.
session_lines() {
  LC_ALL=C awk 'FILENAME == ARGV[1] { t = substr($0, index($0, "\t") + 1); sub(/\r$/, "", t); seen[t] = 1; next }
    { t = substr($0, index($0, "\t") + 1); sub(/\r$/, "", t) }
    (t in seen) { printf "%d\t%s\n", $0 + 0, t }' "$2" "$1" > "$3" 2>/dev/null || : > "$3"
}

# lf_copy <file> <out file> -> <file> with each line's trailing CR dropped.
lf_copy() {
  LC_ALL=C awk '{ sub(/\r$/, "") } 1' "$1" > "$2" 2>/dev/null
}

# Skipping what an earlier Stop judged. A file whose checks passed gets a
# `checked` event (lib/session-event.sh) naming what the verdict was a
# function of: the blob id of the bytes judged (a copy taken before judging,
# so no other bytes took part), the number of Bash-write pairs judged with
# them (pairs are only ever appended, so the same number is the same pairs),
# and a signature of the rules (the blob ids, cut to 12 hex digits, of the
# lib files content_checked_load names, so a plugin update judges again) and
# of the aiDir, which decides the frontmatter and reuse-audit scope. A later
# Stop skips the file only when all of that is what it is now; anything else
# is judged as before. A verdict that also read something else is never
# recorded: a pair whose before or after fell back to HEAD or to the file
# itself ("?", "@"), a snapshot that could not be read (it may be readable
# later), a file git ignores (un-ignoring it brings it into scope). A finding
# records nothing, so a file that failed is judged at every Stop until it
# passes. When a hash cannot be taken, nothing is skipped and nothing is
# recorded.

# content_hashes <path>... -> sets CONTENT_HASHES to the blob id of each
# file's bytes (unfiltered, nothing written to an object store), from one git
# call. Fails unless git named every one.
CONTENT_HASHES=()
content_hashes() {
  local id
  CONTENT_HASHES=()
  while IFS= read -r id; do
    CONTENT_HASHES+=("$id")
  done < <(printf '%s\n' "$@" | git hash-object --no-filters --stdin-paths 2>/dev/null || true)
  [ "${#CONTENT_HASHES[@]}" -eq "$#" ]
}

# content_checked_load <tmp dir> -> sets CONTENT_RULES, the rules half of the
# signature (empty when it cannot be taken: nothing is then skipped or
# recorded), and writes <tmp dir>/checked: each `checked` record of a file
# that still exists (session_content_checked), with the blob id of the file
# as it is now appended. Reads STATE_HOME, SESSION_ID, HOOK_LIB.
content_checked_load() {
  local line root rest i rules
  local -a paths=() recs=()
  CONTENT_RULES=""
  : > "$1/checked"
  for rest in content-checks.sh markdown-section-check.sh stop-gate/content.sh session-event.sh \
      hook-core.sh myspec-config.schema.json; do
    paths+=("$HOOK_LIB/$rest")
  done
  rules=${#paths[@]}
  while IFS= read -r line; do
    root=${line%%$'\t'*}
    rest=${line#*$'\t'}
    [ -f "$root/${rest%%$'\t'*}" ] || continue
    paths+=("$root/${rest%%$'\t'*}")
    recs+=("$line")
  done < <(session_content_checked "$STATE_HOME" "$SESSION_ID")
  content_hashes "${paths[@]}" || return 0
  for ((i = 0; i < rules; i++)); do
    CONTENT_RULES+="${CONTENT_HASHES[i]:0:12}."
  done
  for ((i = 0; i < ${#recs[@]}; i++)); do
    printf '%s\t%s\n' "${recs[i]}" "${CONTENT_HASHES[i + rules]}"
  done > "$1/checked"
}

# content_checked_record <record>... -> appends a `checked` event for each
# `<copy>\t<root>\t<rel>\t<pairs>\t<sig>` record, <copy> being the bytes that
# were judged. Recording is an optimisation: a failure here records nothing
# and the files are judged again.
content_checked_record() {
  local rec i=0
  local -a copies=()
  for rec in "$@"; do
    copies+=("${rec%%$'\t'*}")
  done
  content_hashes "${copies[@]}" || return 0
  for rec in "$@"; do
    printf '%s\t%s\n' "${CONTENT_HASHES[i]}" "${rec#*$'\t'}"
    i=$((i + 1))
  done | jq -R -c 'split("\t") | select(length == 5)
      | {t: "checked", root: .[1], rel: .[2], blob: .[0], pairs: (.[3] | tonumber), sig: .[4]}' 2>/dev/null \
    | session_append_many "$STATE_HOME" "$SESSION_ID" || true
}

# content_gates -> runs the checks above over the session's Bash writes and
# blocks (decision_block exits) when any fails. Reads STATE_HOME, SESSION_ID,
# ORIG_ROOT (arm_init).
content_gates() {
  local root rel abs ai lines text findings matches n m where pairs
  local before after created fm_changed tmp first fm_from fm_to fm_seen fm_before fm_after
  local based readable fm_on prev_after prev_kept prev_fm reuse_ai
  local count was cur sure found idx=0
  local -a reasons=() passed=()
  [ -n "${SESSION_ID:-}" ] || return 0
  pairs=$(session_bash_writes "$STATE_HOME" "$SESSION_ID")
  [ -n "$pairs" ] || return 0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/.myspec-content.XXXXXX")
  CONTENT_ROOTS=() CONTENT_ROOT_OKS=() CONTENT_ROOT_AIS=() CONTENT_ROOT_DEFAULTS=()
  printf '%s\n' "$pairs" > "$tmp/pairs"
  content_checked_load "$tmp"
  # Each file once, in first-written order; its pairs in order. <count> is the
  # number of its pairs, <was> the signature its bytes as they are now were
  # last judged clean under with that many pairs, else "-".
  while IFS=$'\t' read -r count was root rel; do
    [ -n "$root" ] || continue
    [ -n "$rel" ] || continue
    content_root_facts "$root"
    [ "$CONTENT_ROOT_OK" -eq 1 ] || continue
    abs="$root/$rel"
    [ -f "$abs" ] || continue
    ai=$CONTENT_AI
    # Judged clean already, as it is now, under these rules: nothing to do.
    if [ -n "$CONTENT_RULES" ] && [ "$was" = "$CONTENT_RULES $ai" ]; then
      continue
    fi
    # The checks read a copy, so the bytes judged are the bytes recorded.
    idx=$((idx + 1))
    cur="$tmp/cur.$idx"
    sure=1 found=${#reasons[@]}
    if ! cp -- "$abs" "$cur" 2>/dev/null; then
      cur=$abs sure=0
    fi
    case "$ai" in *$'\t'*|*$'\n'*) sure=0 ;; esac
    created=0 fm_changed=0 first=1 based=0 fm_from="" fm_to="" fm_seen=0
    prev_after="" prev_kept="" prev_fm=""
    fm_on=0
    if [ -n "$ai" ] && frontmatter_scope "$ai" "$rel"; then
      fm_on=1
    fi
    : > "$tmp/added"
    while IFS=$'\t' read -r _ _ before after; do
      CONTENT_KEPT=0
      readable=1
      content_before "$root" "$rel" "$before" "$tmp/before" || readable=0 sure=0
      case "$before$after" in *\?*|*@*) sure=0 ;; esac
      # No file before and none after (a failed `sed -i` on a missing file):
      # no write to this file.
      if [ "$CONTENT_NEW" -eq 1 ] && [ "$after" = "-" ]; then
        continue
      fi
      # Created: no file before the session's first write to it. The first
      # pair decides even when its content cannot be read: whether a file
      # was there is in its before token (content_before sets CONTENT_NEW
      # before it reads anything).
      [ "$first" -eq 0 ] || created=$CONTENT_NEW
      first=0
      [ "$readable" -eq 1 ] || continue
      # The baseline of the net diff: the first content read.
      if [ "$based" -eq 0 ]; then
        lf_copy "$tmp/before" "$tmp/base" && based=1
      fi
      if [ "$after" = "-" ]; then
        # The write removed the file.
        : > "$tmp/after"
      elif [ "$after" = "@" ]; then
        # Neither hashed nor kept: the file as it is now.
        cat -- "$cur" > "$tmp/after" 2>/dev/null || continue
        CONTENT_KEPT=1
      elif ! content_snapshot "$root" "$after" "$tmp/after"; then
        sure=0
        continue
      fi
      if [ "$CONTENT_KEPT" -eq 1 ]; then
        # A side that skipped git's line-ending conversion: CRs are dropped
        # on both, as the conversion may have dropped them from a blob.
        lf_copy "$tmp/after" "$tmp/lf" && mv "$tmp/lf" "$tmp/after"
        lf_copy "$tmp/before" "$tmp/lf" && mv "$tmp/lf" "$tmp/before"
      fi
      added_lines "$tmp/before" "$tmp/after" "$tmp/pair"
      cat "$tmp/pair" >> "$tmp/added"
      # The frontmatter region before the first write that changed it, and
      # after the last one: equal when the session restored it. Only for a
      # doc the frontmatter gate covers; a pair whose before is the previous
      # pair's after (read the same way) reuses that region.
      if [ "$fm_on" -eq 1 ]; then
        case "$before" in
          -|\?|@) fm_before=$(frontmatter_region "$tmp/before") ;;
          *)
            if [ "$before" = "$prev_after" ] && [ "$CONTENT_KEPT" = "$prev_kept" ]; then
              fm_before=$prev_fm
            else
              fm_before=$(frontmatter_region "$tmp/before")
            fi
            ;;
        esac
        fm_after=$(frontmatter_region "$tmp/after")
        prev_after=$after prev_kept=$CONTENT_KEPT prev_fm=$fm_after
        if [ "$fm_before" != "$fm_after" ]; then
          [ "$fm_seen" -eq 1 ] || fm_from=$fm_before
          fm_to=$fm_after fm_seen=1
        fi
      fi
    done < <(LC_ALL=C awk -F'\t' -v r="$root" -v p="$rel" '$1 == r && $2 == p' "$tmp/pairs")
    [ "$fm_seen" -eq 0 ] || [ "$fm_from" = "$fm_to" ] || fm_changed=1
    # The lines the file gained since the session's first write that one of
    # its writes added.
    : > "$tmp/numbered"
    if [ "$based" -eq 1 ]; then
      if lf_copy "$cur" "$tmp/now"; then
        added_lines "$tmp/base" "$tmp/now" "$tmp/net"
        session_lines "$tmp/net" "$tmp/added" "$tmp/numbered"
      else
        sure=0
      fi
    fi

    # Absolute homedir paths, on the lines the session added. Not in a file
    # git ignores (absolute_paths_scope), which is then not recorded either.
    if git -C "$root" check-ignore -q -- "$rel" 2>/dev/null; then
      sure=0
    elif absolute_paths_scope_unignored "$root" "$rel" "$ai" && [ -s "$tmp/numbered" ]; then
      cut -f2- "$tmp/numbered" > "$tmp/text"
      matches=$(absolute_path_findings "$tmp/text")
      if [ -n "$matches" ]; then
        findings=""
        while IFS=$'\t' read -r n m; do
          [ -n "$m" ] || continue
          where=$(LC_ALL=C awk -F'\t' -v k="$n" 'NR == k { print $1; exit }' "$tmp/numbered")
          findings="${findings}line ${where:-?}"$'\t'"${m}"$'\n'
        done <<< "$matches"
        reasons+=("$(absolute_paths_reason "lines this session added to" "$rel" "$root" "$findings")")
      fi
    fi

    # Frontmatter, on a doc the session created or whose frontmatter region
    # its writes changed on net.
    if [ "$fm_on" -eq 1 ] && [ $((created + fm_changed)) -gt 0 ]; then
      lines=$(frontmatter_issues "$cur")
      [ -z "$lines" ] || reasons+=("$(frontmatter_reason "$rel" "$lines" "$ai")")
    fi

    # The reuse audit, on a tech-spec the session created.
    reuse_ai=$ai
    if [ "$created" -eq 1 ] && [ -z "$reuse_ai" ]; then
      content_root_default_ai
      reuse_ai=$CONTENT_AI_DEFAULT
    fi
    if [ "$created" -eq 1 ] && reuse_audit_scope "$reuse_ai" "$rel"; then
      lines=$(reuse_audit_issues "$cur")
      [ -z "$lines" ] || reasons+=("$(reuse_audit_reason "$rel" "$lines")")
    fi
    if [ "$sure" -eq 1 ] && [ -n "$CONTENT_RULES" ] && [ "${#reasons[@]}" -eq "$found" ]; then
      passed+=("$cur"$'\t'"$root"$'\t'"$rel"$'\t'"$count"$'\t'"$CONTENT_RULES $ai")
    fi
  done < <(LC_ALL=C awk -F'\t' '
    FILENAME == ARGV[1] { if ($3 == $6 && $5 != "") { n[$1 FS $2] = $4; sig[$1 FS $2] = $5 } next }
    { k = $1 FS $2; if (!(k in c)) order[++m] = k; c[k]++ }
    END {
      for (i = 1; i <= m; i++) {
        k = order[i]
        print c[k] FS ((k in n) && n[k] == c[k] ? sig[k] : "-") FS k
      }
    }' "$tmp/checked" "$tmp/pairs")
  [ "${#passed[@]}" -eq 0 ] || content_checked_record "${passed[@]}"
  rm -rf "$tmp"
  [ "${#reasons[@]}" -gt 0 ] || return 0
  text=""
  for rel in "${reasons[@]}"; do
    text+="${rel}"$'\n---\n'
  done
  decision_block 'Content checks failed for files this session wrote. The Write and Edit hooks check what those calls propose; a Bash write (a heredoc, sed -i, tee) is checked here, on the lines it added. Fix these before stopping:\n\n%s' "${text%$'\n---\n'}"
}
