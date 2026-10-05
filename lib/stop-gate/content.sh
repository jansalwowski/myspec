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
# PreToolUse and after the write). Write and Edit calls are not here: their
# PreToolUse hooks judged them. Per file in a checkout of this repository (or
# nested in the cwd's tree) that still exists:
#   - the lines judged are the lines of the file as it is now whose text one
#     of the session's Bash writes added (the `+` lines of before -> after).
#     A line the file held before the session, or another session wrote, is
#     not one; a line this session added and then committed still is;
#   - absolute homedir paths, on those lines, for the files the rule covers
#     (absolute_paths_scope; only those get snapshots);
#   - frontmatter, on a ${aiDir} markdown doc a Bash write created or whose
#     frontmatter region one changed;
#   - the reuse audit, on a tech-spec a Bash write created.
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

# session_lines <file> <added> <out file> -> writes `<line>\t<text>` for each
# line of <file> whose text is one of the <added> lines (`<n>\t<text>`, as
# added_lines writes them): what the session added that the file still holds.
# A trailing CR is dropped on both sides: the blobs went through git's
# line-ending conversion (core.autocrlf, `text eol=crlf`), the working file
# did not, so a CRLF line would otherwise never match its added text.
session_lines() {
  LC_ALL=C awk 'NR == FNR { t = substr($0, index($0, "\t") + 1); sub(/\r$/, "", t); seen[t] = 1; next }
    { t = $0; sub(/\r$/, "", t) }
    (t in seen) { printf "%d\t%s\n", FNR, t }' "$2" "$1" > "$3" 2>/dev/null || : > "$3"
}

# content_gates -> runs the checks above over the session's Bash writes and
# blocks (decision_block exits) when any fails. Reads STATE_HOME, SESSION_ID,
# ORIG_ROOT (arm_init).
content_gates() {
  local root rel abs ai lines text findings matches n m where pairs file
  local before after created fm_changed tmp
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
    created=0 fm_changed=0
    : > "$tmp/added"
    while IFS=$'\t' read -r _ _ before after; do
      CONTENT_KEPT=0
      content_before "$root" "$rel" "$before" "$tmp/before" || continue
      if [ "$after" = "@" ]; then
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
      [ "$CONTENT_NEW" -eq 0 ] || created=1
      added_lines "$tmp/before" "$tmp/after" "$tmp/pair"
      cat "$tmp/pair" >> "$tmp/added"
      [ "$(frontmatter_region "$tmp/before")" = "$(frontmatter_region "$tmp/after")" ] || fm_changed=1
    done < <(printf '%s\n' "$pairs" | LC_ALL=C awk -F'\t' -v r="$root" -v p="$rel" '$1 == r && $2 == p')
    session_lines "$abs" "$tmp/added" "$tmp/numbered"

    # Absolute homedir paths, on the lines the session added.
    if absolute_paths_scope "$root" "$rel" && [ -s "$tmp/numbered" ]; then
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

    # Frontmatter, on a doc a Bash write created or whose frontmatter region
    # one changed.
    if [ -n "$ai" ] && frontmatter_scope "$ai" "$rel" && [ $((created + fm_changed)) -gt 0 ]; then
      lines=$(frontmatter_issues "$abs")
      [ -z "$lines" ] || reasons+=("$(frontmatter_reason "$rel" "$lines" "$ai")")
    fi

    # The reuse audit, on a tech-spec a Bash write created.
    if [ "$created" -eq 1 ] && reuse_audit_scope "$rel"; then
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
