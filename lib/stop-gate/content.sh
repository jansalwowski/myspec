#!/usr/bin/env bash
# stop-gate/content.sh
# lint: sourced under set -euo pipefail
# Sourced by hooks/verify-before-stop.sh, after lib/hook-core.sh,
# lib/session-event.sh, lib/content-checks.sh and stop-gate/arm.sh (arm_init);
# never run. The catch-all for writes the PreToolUse content gates never see
# (#263, docs/stop-gate.md R14): a Bash heredoc, `sed -i`, `tee` and the like
# land without a Write or Edit call, so the three checks run here over the
# files this session wrote, on the lines it added. Tests:
# lib/tests/stop-gate-content.test.sh, hooks/tests/verify-before-stop-content.test.sh.
#
# What runs, per file the session's `write` events name in a checkout of
# this repository (or nested in the cwd's tree), that git reports changed
# against HEAD (an unchanged or gitignored file has nothing to check):
#   - absolute homedir paths, on the lines added against HEAD (the whole file
#     when it is not in HEAD), for the files the rule covers
#     (absolute_paths_scope);
#   - frontmatter, on a ${aiDir} markdown doc not in HEAD or whose
#     frontmatter region differs from HEAD's;
#   - the reuse audit, on a tech-spec not in HEAD: one this session created.
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

# content_changed <root> -> sets CONTENT_STATUS: `<rel>\t<xy>` lines for every
# path git reports changed in <root>, uncommitted or untracked (both sides of
# a rename, the new side marked R).
content_changed() {
  local entry second=0
  CONTENT_STATUS=""
  while IFS= read -r -d '' entry; do
    if [ "$second" -eq 1 ]; then
      second=0
      CONTENT_STATUS="$CONTENT_STATUS$entry"$'\t'"R"$'\n'
      continue
    fi
    CONTENT_STATUS="$CONTENT_STATUS${entry:3}"$'\t'"${entry:0:2}"$'\n'
    case "${entry:0:2}" in
      *R*|*C*) second=1 ;;
    esac
  done < <(git -C "$1" status --porcelain=v1 -z --untracked-files=all 2>/dev/null)
}

# content_status <rel> -> the two-letter status of <rel> in CONTENT_STATUS,
# empty when git did not report it.
content_status() {
  local line
  while IFS= read -r line; do
    case "$line" in
      "$1"$'\t'*) printf '%s\n' "${line#*$'\t'}"; return 0 ;;
    esac
  done <<< "$CONTENT_STATUS"
  return 0
}

# in_head <root> <rel> -> 0 when HEAD holds the path.
in_head() {
  git -C "$1" cat-file -e "HEAD:$2" 2>/dev/null
}

# added_lines <root> <rel> <out file> -> writes `<line>\t<text>` for each
# line of <rel> that is not in HEAD's version: the `+` lines of
# `git diff -U0 HEAD`, numbered from the hunk headers, or every line when
# the path is not in HEAD or HEAD cannot be read (an unborn branch). Sets
# CONTENT_WHOLE=1 in the second case.
added_lines() {
  CONTENT_WHOLE=0
  if ! in_head "$1" "$2"; then
    CONTENT_WHOLE=1
    awk '{ printf "%d\t%s\n", NR, $0 }' "$1/$2" > "$3" 2>/dev/null || true
    return 0
  fi
  # The `---`/`+++` header lines precede the first hunk, so only lines after
  # a hunk header count; a line in the body starting with +++ is content.
  git -C "$1" diff -U0 HEAD -- "$2" 2>/dev/null | LC_ALL=C awk '
    /^@@/ { match($0, /\+[0-9]+/); n = substr($0, RSTART + 1, RLENGTH - 1) + 0; hunk = 1; next }
    hunk && /^\+/ { printf "%d\t%s\n", n, substr($0, 2); n++; next }
    hunk && /^ / { n++ }' > "$3" || true
}

# content_gates -> runs the checks above over the session's writes and
# blocks (decision_block exits) when any fails. Reads STATE_HOME, SESSION_ID,
# ORIG_ROOT (arm_init).
content_gates() {
  local root rel abs status ai lines text findings matches n m where
  local -a reasons=()
  local last_root="" numbered cmp
  [ -n "${SESSION_ID:-}" ] || return 0
  numbered=$(mktemp "${TMPDIR:-/tmp}/.myspec-content.XXXXXX")
  text=$(mktemp "${TMPDIR:-/tmp}/.myspec-content.XXXXXX")
  cmp=$(mktemp "${TMPDIR:-/tmp}/.myspec-content.XXXXXX")
  while IFS=$'\t' read -r root rel; do
    [ -n "$root" ] || continue
    [ -n "$rel" ] || continue
    [ -d "$root" ] || continue
    content_root_ok "$root" || continue
    abs="$root/$rel"
    [ -f "$abs" ] || continue
    if [ "$root" != "$last_root" ]; then
      content_changed "$root"
      last_root="$root"
      ai=""
      [ ! -f "$root/.myspec.json" ] || ai=$(ai_dir "$root")
    fi
    # Not in git's status: identical to HEAD and the index, or gitignored.
    status=$(content_status "$rel")
    [ -n "$status" ] || continue
    added_lines "$root" "$rel" "$numbered"

    # Absolute homedir paths, on the added lines.
    if absolute_paths_scope "$root" "$rel" && [ -s "$numbered" ]; then
      cut -f2- "$numbered" > "$text"
      matches=$(absolute_path_findings "$text")
      if [ -n "$matches" ]; then
        findings=""
        while IFS=$'\t' read -r n m; do
          [ -n "$m" ] || continue
          where=$(LC_ALL=C awk -F'\t' -v k="$n" 'NR == k { print $1; exit }' "$numbered")
          findings="${findings}line ${where:-?}"$'\t'"${m}"$'\n'
        done <<< "$matches"
        reasons+=("$(absolute_paths_reason "lines this session added to" "$rel" "$root" "$findings")")
      fi
    fi

    # Frontmatter, on a doc this session created or whose frontmatter region
    # it changed.
    if [ -n "$ai" ] && frontmatter_scope "$ai" "$rel"; then
      if [ "$CONTENT_WHOLE" -eq 1 ]; then
        lines=$(frontmatter_issues "$abs")
      else
        git -C "$root" show "HEAD:$rel" > "$cmp" 2>/dev/null || : > "$cmp"
        lines=""
        [ "$(frontmatter_region "$cmp")" = "$(frontmatter_region "$abs")" ] || lines=$(frontmatter_issues "$abs")
      fi
      [ -z "$lines" ] || reasons+=("$(frontmatter_reason "$rel" "$lines" "$ai")")
    fi

    # The reuse audit, on a tech-spec this session created.
    if [ "$CONTENT_WHOLE" -eq 1 ] && reuse_audit_scope "$rel"; then
      lines=$(reuse_audit_issues "$abs")
      [ -z "$lines" ] || reasons+=("$(reuse_audit_reason "$rel" "$lines")")
    fi
  done < <(session_writes "$STATE_HOME" "$SESSION_ID")
  rm -f "$numbered" "$text" "$cmp"
  [ "${#reasons[@]}" -gt 0 ] || return 0
  text=""
  for rel in "${reasons[@]}"; do
    text+="${rel}"$'\n---\n'
  done
  decision_block 'Content checks failed for files this session wrote. The Write and Edit hooks check what those calls propose; a Bash write (a heredoc, sed -i, tee) is checked here, on the lines it added. Fix these before stopping:\n\n%s' "${text%$'\n---\n'}"
}
