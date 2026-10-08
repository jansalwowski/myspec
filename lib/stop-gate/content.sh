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
#   - the lines judged are the lines the session's Bash writes added on net
#     and the file still holds. Per line text, each pair counts its `+` lines
#     less its `-` lines (session_lines); a text whose sum is above zero has
#     that many session copies. A line the file held before the session, or
#     another session wrote, is not one: a write that changes a line and a
#     later one that restores it sum to zero for both texts, and a line moved
#     within the file sums to zero. A line this session added and then
#     committed still is;
#   - absolute homedir paths, on those lines, for the files the rule covers
#     (absolute_paths_scope; only those get snapshots);
#   - frontmatter, on a ${aiDir} markdown doc the session created, or whose
#     frontmatter region its writes left different from what they found;
#   - the reuse audit, on a tech-spec the session created.
# "Created" means the file did not exist before the session's first Bash
# write to it, so a file deleted and recreated (`mv` away and back) is
# not created.
#
# Why the pairs and not the net diff of the file's earliest snapshot against
# the file now (#343): between two of the session's Bash writes another
# session, an Edit or Write call, or the user may change the file, and those
# changes sit between one pair's after and the next pair's before, so the
# pairs never count them, while an earliest-to-now diff would sweep them in.
# Dropping from a union of `+` lines every text the earliest snapshot held
# would miss a second copy the session added of a text the file already had;
# the counts catch it, and judge as many copies as the session added
# (preferring the line numbers its writes put them at, then the last ones).
#
# Each finding blocks the stop with the reason the PreToolUse hook would have
# given. The checks are cheap, and they run inside the gate budget like
# everything else (gate_budget_init runs first). They block during a
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

# pair_lines <old file> <new file> <out file> -> writes `+\t<line>\t<text>`
# for each line of <new file> that is not in <old file> and `-\t<line>\t<text>`
# for each line of <old file> that is not in <new file>: the lines of
# `git diff --no-index -U0`, numbered from the hunk headers (in <new file>
# for a `+` line, in <old file> for a `-` one).
pair_lines() {
  # The `---`/`+++` header lines precede the first hunk, so only lines after
  # a hunk header count; a body line starting with +++ or --- is content.
  git diff --no-index --no-color --no-ext-diff -U0 -- "$1" "$2" 2>/dev/null | LC_ALL=C awk '
    /^@@/ {
      match($0, /-[0-9]+/); o = substr($0, RSTART + 1, RLENGTH - 1) + 0
      match($0, /\+[0-9]+/); n = substr($0, RSTART + 1, RLENGTH - 1) + 0
      hunk = 1; next }
    hunk && /^\+/ { printf "+\t%d\t%s\n", n, substr($0, 2); n++; next }
    hunk && /^-/ { printf "-\t%d\t%s\n", o, substr($0, 2); o++ }' > "$3" || true
}

# session_lines <file> <changes> <out file> -> writes `<line>\t<text>` for
# each line of <file> the session added on net: <changes> holds every pair's
# pair_lines output, and a text counts its `+` lines less its `-` lines. A
# text with a count of k has k copies judged: first the copies at a line
# number one of its `+` lines gave, then the last ones in the file. A
# trailing CR is dropped on every side: the blobs went through git's
# line-ending conversion (core.autocrlf, `text eol=crlf`), the working file
# did not, so a CRLF line would otherwise never match its added text.
session_lines() {
  LC_ALL=C awk -F'\t' '
    FILENAME == ARGV[1] {
      t = $0; sub(/^[^\t]*\t[^\t]*\t/, "", t); sub(/\r$/, "", t)
      if ($1 == "+") { d[t]++; at[$2 "\t" t] = 1 } else if ($1 == "-") d[t]--
      next }
    { t = $0; sub(/\r$/, "", t); line[++n] = t }
    END {
      for (i = n; i >= 1; i--) { t = line[i]; if (d[t] > 0 && ((i "\t" t) in at)) { pick[i] = 1; d[t]-- } }
      for (i = n; i >= 1; i--) { t = line[i]; if (!(i in pick) && d[t] > 0) { pick[i] = 1; d[t]-- } }
      for (i = 1; i <= n; i++) if (i in pick) printf "%d\t%s\n", i, line[i]
    }' "$2" "$1" > "$3" 2>/dev/null || : > "$3"
}

# content_gates -> runs the checks above over the session's Bash writes and
# blocks (decision_block exits) when any fails. Reads STATE_HOME, SESSION_ID,
# ORIG_ROOT (arm_init).
content_gates() {
  local root rel abs ai lines text findings matches n m where pairs file
  local before after created fm_changed tmp first fm_from fm_to fm_seen fm_before fm_after
  local -a reasons=()
  [ -n "${SESSION_ID:-}" ] || return 0
  pairs=$(session_bash_writes "$STATE_HOME" "$SESSION_ID")
  [ -n "$pairs" ] || return 0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/.myspec-content.XXXXXX")
  # Each file once, in first-written order; its pairs in order.
  while IFS= read -r file; do
    root="${file%%$'\t'*}"
    rel="${file#*$'\t'}"
    [ -n "$root" ] || continue
    [ -n "$rel" ] || continue
    [ -d "$root" ] || continue
    content_root_ok "$root" || continue
    abs="$root/$rel"
    [ -f "$abs" ] || continue
    ai=""
    [ ! -f "$root/.myspec.json" ] || ai=$(ai_dir "$root")
    created=0 fm_changed=0 first=1 fm_from="" fm_to="" fm_seen=0
    : > "$tmp/changes"
    while IFS=$'\t' read -r _ _ before after; do
      CONTENT_KEPT=0
      content_before "$root" "$rel" "$before" "$tmp/before" || continue
      if [ "$after" = "-" ]; then
        # The write removed the file.
        : > "$tmp/after"
      elif [ "$after" = "@" ]; then
        # Neither hashed nor kept: the file as it is now.
        cat -- "$abs" > "$tmp/after" 2>/dev/null || continue
        CONTENT_KEPT=1
      else
        content_snapshot "$root" "$after" "$tmp/after" || continue
      fi
      if [ "$CONTENT_KEPT" -eq 1 ]; then
        # A side that skipped git's line-ending conversion: CRs are dropped
        # on both, as the conversion may have dropped them from a blob.
        LC_ALL=C awk '{ sub(/\r$/, "") } 1' "$tmp/after" > "$tmp/lf" && mv "$tmp/lf" "$tmp/after"
        LC_ALL=C awk '{ sub(/\r$/, "") } 1' "$tmp/before" > "$tmp/lf" && mv "$tmp/lf" "$tmp/before"
      fi
      # Created: no file before the session's first write to it.
      [ "$first" -eq 0 ] || created=$CONTENT_NEW
      first=0
      pair_lines "$tmp/before" "$tmp/after" "$tmp/pair"
      cat "$tmp/pair" >> "$tmp/changes"
      # The frontmatter region before the first write that changed it, and
      # after the last one: equal when the session restored it.
      fm_before=$(frontmatter_region "$tmp/before")
      fm_after=$(frontmatter_region "$tmp/after")
      if [ "$fm_before" != "$fm_after" ]; then
        [ "$fm_seen" -eq 1 ] || fm_from=$fm_before
        fm_to=$fm_after fm_seen=1
      fi
    done < <(printf '%s\n' "$pairs" | LC_ALL=C awk -F'\t' -v r="$root" -v p="$rel" '$1 == r && $2 == p')
    [ "$fm_seen" -eq 0 ] || [ "$fm_from" = "$fm_to" ] || fm_changed=1
    session_lines "$abs" "$tmp/changes" "$tmp/numbered"

    # Absolute homedir paths, on the lines the session added.
    if absolute_paths_scope "$root" "$rel" "$ai" && [ -s "$tmp/numbered" ]; then
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
    if [ -n "$ai" ] && frontmatter_scope "$ai" "$rel" && [ $((created + fm_changed)) -gt 0 ]; then
      lines=$(frontmatter_issues "$abs")
      [ -z "$lines" ] || reasons+=("$(frontmatter_reason "$rel" "$lines" "$ai")")
    fi

    # The reuse audit, on a tech-spec the session created.
    if [ "$created" -eq 1 ] && reuse_audit_scope "${ai:-$(ai_dir "$root")}" "$rel"; then
      lines=$(reuse_audit_issues "$abs")
      [ -z "$lines" ] || reasons+=("$(reuse_audit_reason "$rel" "$lines")")
    fi
  done < <(printf '%s\n' "$pairs" | LC_ALL=C awk -F'\t' '!seen[$1 "\t" $2]++ { print $1 "\t" $2 }')
  rm -rf "$tmp"
  [ "${#reasons[@]}" -gt 0 ] || return 0
  text=""
  for rel in "${reasons[@]}"; do
    text+="${rel}"$'\n---\n'
  done
  decision_block 'Content checks failed for files this session wrote. The Write and Edit hooks check what those calls propose; a Bash write (a heredoc, sed -i, tee) is checked here, on the lines it added. Fix these before stopping:\n\n%s' "${text%$'\n---\n'}"
}
