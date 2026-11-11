#!/usr/bin/env bash
# markdown-section-check.sh
# Helpers for validating a required markdown section and its table inside a
# generated document (e.g. the `### Reuse audit` section in tech-spec.md).
# Source this file; do not execute directly.
#
# All functions take a <file> and a <heading> (the heading TEXT, without `#`
# markers). Heading matching tolerates H2 or H3, surrounding/trailing
# whitespace, and is case-insensitive on the heading text. Case-insensitivity
# is done via tolower() on both sides — NOT awk IGNORECASE, which is a
# gawk-only extension absent from BWK awk (the macOS / BSD default).
#
# Each assert_* function prints a one-line diagnostic to stdout on failure and
# returns 1. On success they return 0 and print nothing. They return 2 when
# their own awk or grep failed: what they printed, or did not, is then not a
# verdict (an awk that fails finds no heading and no bad row). Callers
# (reuse_audit_issues in content-checks.sh, future CI) compose these and build
# the block reason.

# _heading_lineno <file> <heading>
# Print the 1-based line number of the first matching heading, or nothing.
# Its status is awk's.
_heading_lineno() {
  local file="$1" heading="$2"
  awk -v h="$heading" '
    BEGIN { gsub(/[.[\](){}+*?^$|\\]/, "\\\\&", h); h = tolower(h) }
    tolower($0) ~ "^#{2,3}[ \t]+" h "[ \t]*$" { print NR; exit }
  ' "$file" 2>/dev/null
}

# assert_section_present <file> <heading>
# The heading must exist as `## <heading>` or `### <heading>`.
assert_section_present() {
  local file="$1" heading="$2" ln failed=0
  if [ ! -f "$file" ]; then
    printf 'file not found: %s\n' "$file"
    return 1
  fi
  ln="$(_heading_lineno "$file" "$heading")" || failed=1
  if [ -z "$ln" ]; then
    printf 'missing required section: "## %s" (or ### )\n' "$heading"
    return $((1 + failed))
  fi
  return 0
}

# _table_data_rows <file> <start_lineno>
# Emit the table data rows that follow start_lineno: the first contiguous
# block of pipe-rows after the heading, minus the header row and the
# `|---|` separator row. Blank lines between the heading and the table are
# tolerated; the block ends at the first non-pipe, non-blank line after the
# table starts. Its status is awk's.
_table_data_rows() {
  local file="$1" start="$2"
  awk -v start="$start" '
    NR <= start { next }
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      if (line ~ /^\|/) {
        intable = 1
        rownum++
        # row 1 = header, row 2 = separator (|---|:--| etc.)
        if (rownum <= 2) next
        if (line ~ /^\|[ \t:|-]+\|[ \t]*$/) next   # extra separator safety
        print line
        next
      }
      if (line == "") {
        if (intable) exit          # blank line after table ends the block
        next                        # blank line before table is fine
      }
      if (intable) exit             # any non-pipe line ends the table
    }
  ' "$file" 2>/dev/null
}

# assert_table_after_heading <file> <heading> <min_rows>
# A markdown table must follow the heading with at least <min_rows> data rows.
assert_table_after_heading() {
  local file="$1" heading="$2" min_rows="${3:-1}"
  local ln rows count failed=0
  ln="$(_heading_lineno "$file" "$heading")" || failed=1
  if [ -z "$ln" ]; then
    printf 'missing required section: "## %s"\n' "$heading"
    return $((1 + failed))
  fi
  rows="$(_table_data_rows "$file" "$ln")" || failed=1
  if [ -z "$rows" ]; then
    count=0
  else
    # Every row is a non-empty line, so grep matches: any other status is its
    # failure, and no count is no verdict.
    count="$(grep -c . <<< "$rows")" || return 2
  fi
  if [ "$count" -lt "$min_rows" ]; then
    printf 'section "%s" has %d data row(s); need >= %d\n' "$heading" "$count" "$min_rows"
    return $((1 + failed))
  fi
  [ "$failed" -eq 0 ] || return 2
  return 0
}

# assert_reuse_audit_rows <file> <heading>
# Reuse-audit-table-specific. Every data row must have 4 non-empty cells;
# the Decision cell (col 3) must be exactly `reuse` or `skip`
# (case-insensitive); every `skip` row must carry a non-empty, non-dash
# Reason (col 4). Format-specific by design — the two helpers above are
# generic; this one knows the table shape.
assert_reuse_audit_rows() {
  local file="$1" heading="$2"
  local ln rows failed=0
  ln="$(_heading_lineno "$file" "$heading")" || failed=1
  if [ -z "$ln" ]; then
    printf 'missing required section: "## %s"\n' "$heading"
    return $((1 + failed))
  fi
  rows="$(_table_data_rows "$file" "$ln")" || failed=1
  if [ -z "$rows" ]; then
    printf 'section "%s" has no data rows\n' "$heading"
    return $((1 + failed))
  fi

  local failure
  failure="$(awk '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    {
      # Split a leading-and-trailing-pipe row into cells.
      n = split($0, parts, "|")
      # parts[1] is empty (before first pipe), parts[n] empty (after last).
      cand = trim(parts[2]); surf = trim(parts[3])
      dec  = trim(parts[4]); rea  = trim(parts[5])
      colcount = n - 2
      if (colcount != 4) {
        printf "row %d: expected 4 columns, found %d: %s\n", NR, colcount, $0
        next
      }
      if (cand == "" || surf == "") {
        printf "row %d: Candidate/Surface must be non-empty: %s\n", NR, $0
        next
      }
      ld = tolower(dec)
      if (ld != "reuse" && ld != "skip") {
        printf "row %d: Decision must be reuse or skip, got \"%s\"; a component reused with changes is reuse, with the change in Reason\n", NR, dec
        next
      }
      if (ld == "skip") {
        if (rea == "" || rea == "-" || rea == "--" || rea == "\xe2\x80\x94" || rea == "\xe2\x80\x93") {
          printf "row %d: skip rows require a non-empty Reason\n", NR
          next
        }
      }
    }
  ' <<< "$rows")" || failed=1

  if [ -n "$failure" ]; then
    printf '%s\n' "$failure"
    return $((1 + failed))
  fi
  [ "$failed" -eq 0 ] || return 2
  return 0
}
