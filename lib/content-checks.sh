#!/usr/bin/env bash
# content-checks.sh
# Sourced, never run. The three content gates in one place: absolute homedir
# paths (framework-files/rules/paths.md), frontmatter on ${aiDir} docs, and
# the reuse audit in a tech-spec. Each runs twice over the same functions:
#   - at PreToolUse, on the content a Write, Edit, MultiEdit or NotebookEdit
#     proposes (hooks/no-absolute-paths.sh, hooks/validate-frontmatter.sh,
#     hooks/require-reuse-audit.sh), which denies the call;
#   - at Stop, on the lines a Bash write added (lib/stop-gate/content.sh),
#     which those hooks never see.
# Neither rescans a file for what was already there: an Edit is judged by what
# it adds or changes, a Bash write by the diff between its before and after
# snapshots (#263). The
# reasons both print are built here, so the two paths say the same thing.
# Sourced after lib/hook-core.sh (HOOK_LIB, ai_dir, physical paths); it
# sources lib/markdown-section-check.sh beside it (the reuse-audit table
# checks). bash 3.2 compatible (macOS /bin/bash).
# shellcheck disable=SC2034 # PROPOSED_KIND is read by the callers

if ! declare -F assert_reuse_audit_rows >/dev/null 2>&1; then
  # shellcheck source=lib/markdown-section-check.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/markdown-section-check.sh"
fi

# --- proposed content ---------------------------------------------------------

# jq, over a tool_input with $cur (the file's content): the content an Edit
# or MultiEdit leaves. Splitting on old_string is linear in the file; bash's
# ${content/old/new} on the whole file is quadratic under bash 3.2 (macOS
# /bin/bash), a minute at 200 KB, past the hook timeout (PR #274 review).
# The first occurrence: the text before the first split point, new_string,
# and the rest joined back with old_string.
# shellcheck disable=SC2016 # a jq program: $cur, $e, $o are jq variables
PROPOSED_EDIT_JQ='
  (if has("edits") then (.edits | if type == "array" then . else [] end) else [.] end)
  | reduce .[] as $e ($cur;
      (($e.old_string | strings) // "") as $o
      | (($e.new_string | strings) // "") as $n
      | if $o == "" then (if . == "" then $n else . end)
        elif ($e.replace_all // false) == true then split($o) | join($n)
        else split($o) as $p
          | if ($p | length) < 2 then . else $p[0] + $n + ($p[1:] | join($o)) end
        end)'

# proposed_content <tool_input json> <current file> <out file> -> writes the
# content the call would leave in the file: a Write's `content` as is; an
# Edit or MultiEdit applied in memory to the current file (first occurrence,
# every occurrence with replace_all; an old_string the file does not hold
# leaves it unchanged, as the tool then fails; an empty old_string on an
# empty or missing file is a create), in one jq run. Sets PROPOSED_KIND to
# write, edit or multi. Fails, writing nothing, when the call carries no
# content.
proposed_content() {
  local input="$1" cur="$2" out="$3"
  local -a src=(--arg cur "")
  PROPOSED_KIND=$(printf '%s' "$input" | jq -r 'if type != "object" then "" elif has("content") then "write" elif has("edits") then "multi" elif has("new_string") then "edit" else "" end' 2>/dev/null || printf '')
  case "$PROPOSED_KIND" in
    write)
      printf '%s' "$input" | jq -j '.content | strings' > "$out" 2>/dev/null || return 1
      ;;
    edit|multi)
      [ ! -f "$cur" ] || src=(--rawfile cur "$cur")
      printf '%s' "$input" | jq -j "${src[@]}" "$PROPOSED_EDIT_JQ" > "$out" 2>/dev/null || return 1
      ;;
    *) return 1 ;;
  esac
}

# --- absolute homedir paths ---------------------------------------------------

# The detected shapes. The absolute forms (/Users, /home) must stand at a
# path ROOT, preceded by start-of-line or a non-path character, so a relative
# segment such as `components/home/HomeFoo.vue` (a `home/` directory followed
# by a Capitalized name) is not one. grep ERE has no lookbehind, so the
# boundary is captured and stripped by absolute_path_findings.
#   /Users/<name>...        e.g. /Users/alice/work/foo   (root only)
#   /home/<name>...         e.g. /home/alice/work/foo     (root only)
#   -Users-<name>-...       the encoded form of /Users/<name>/... (leading - kept)
#   -home-<name>-...        the encoded form of /home/<name>/...   (leading - kept)
ABSOLUTE_PATH_RE='(^|[^A-Za-z0-9._/-])(/Users/[A-Za-z][A-Za-z0-9._-]*|/home/[A-Za-z][A-Za-z0-9._-]*)|(-Users-[A-Za-z][A-Za-z0-9._-]+|-home-[A-Za-z][A-Za-z0-9._-]+)'

# absolute_paths_scope <repo root> <repo-relative path> [aiDir] -> 0 when the
# file is one the rule covers (#163): a doc kind anywhere (*.md, *.mdx,
# *.markdown, *.txt, *.rst, *.adoc), or any file under .claude/, docs/ or the
# project aiDir (.myspec.json; a repository without one has no aiDir in
# scope). A caller asking per file passes the aiDir it resolved once (ai_dir
# in hook-core.sh runs the settings reader). App code, Dockerfiles and CI
# workflows are out: a route such as /home/Dashboard or a container path such
# as /home/node/app is not a developer home. Also out: anything under .git/,
# a gitignored file (never committed), and the plugin's own files that define
# the shapes.
absolute_paths_scope() {
  local root="$1" rel="$2" ai="${3:-}"
  case "$rel" in
    .git/*|*/.git/*) return 1 ;;
    lib/path-normalize.sh|lib/content-checks.sh) return 1 ;;
  esac
  if git -C "$root" check-ignore -q -- "$rel" 2>/dev/null; then
    return 1
  fi
  case "$rel" in
    *.md|*.mdx|*.markdown|*.txt|*.rst|*.adoc|.claude/*|docs/*) return 0 ;;
  esac
  if [ -f "$root/.myspec.json" ]; then
    [ -n "$ai" ] || ai=$(ai_dir "$root")
    case "$rel" in
      "$ai"/*) return 0 ;;
    esac
  fi
  return 1
}

# absolute_path_findings <file> -> at most ten `<line>\t<match>` lines, the
# line being the match's line in <file> and the match the path with its
# boundary character stripped. Nothing when the file is clean.
absolute_path_findings() {
  local line n m
  # awk, not head: it reads all of grep's output, so no SIGPIPE under pipefail.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n="${line%%:*}"
    m="${line#*:}"
    case "$m" in
      /*|-Users-*|-home-*) : ;;
      *) m="${m#?}" ;;
    esac
    printf '%s\t%s\n' "$n" "$m"
  done < <(grep -noE "$ABSOLUTE_PATH_RE" "$1" 2>/dev/null | awk 'NR <= 10' || true)
}

# absolute_path_hint <match> <repo root> -> the replacement to suggest.
absolute_path_hint() {
  local match="$1" root="$2" rel rest first dir
  local hint="use <repo_root>/<relative-path> for repo-internal paths, or <config_dir>/projects/<encoded_cwd>/... for the harness memory store (<config_dir> is \$CLAUDE_CONFIG_DIR, default ~/.claude)"
  case "$match" in
    "$root"*)
      rel="${match#"$root"}"
      rel="${rel#/}"
      if [ -z "$rel" ]; then
        hint="replace with <repo_root>"
      else
        hint="replace with <repo_root>/$rel"
      fi
      ;;
  esac
  # The memory store under a Claude config dir: $CLAUDE_CONFIG_DIR, ~/.claude,
  # or ~/.claude-personal (config_projects_rest in path-normalize.sh).
  for dir in "${CLAUDE_CONFIG_DIR:-}" "${HOME:+$HOME/.claude}" "${HOME:+$HOME/.claude-personal}"; do
    dir="${dir%/}"
    [ -n "$dir" ] || continue
    case "$match" in
      "$dir"/projects/?*)
        rest="${match#"$dir"/projects/}"
        first="${rest%%/*}"
        rel=""
        [ "$first" = "$rest" ] || rel="/${rest#"$first"/}"
        hint="replace with <config_dir>/projects/<encoded_cwd>$rel"
        break
        ;;
    esac
  done
  printf '%s\n' "$hint"
}

# absolute_paths_reason <what> <rel path> <repo root> <findings> -> the
# reason, where <findings> are `<where>\t<match>` lines (<where> names the
# line: "line 3", "new text line 1") and <what> opens the sentence ("the
# content proposed for", "lines this session added to").
absolute_paths_reason() {
  local what="$1" rel="$2" root="$3" findings="$4" where match hint=""
  while IFS=$'\t' read -r where match; do
    [ -n "$match" ] || continue
    hint="${hint}  ${where}: ${match}
    → $(absolute_path_hint "$match" "$root")
"
  done <<< "$findings"
  cat <<EOF
BLOCKED: ${what} ${rel} contains absolute homedir paths. Committed docs and framework files must be portable across machines and users, so use the placeholders <repo_root> and <encoded_cwd> instead (helper: ${HOOK_LIB}/path-normalize.sh).

Findings:
${hint}
Checked by the myspec plugin hook no-absolute-paths.sh on doc files and on files under .claude/, docs/ or the aiDir that git does not ignore. To describe the pattern itself, write a placeholder such as /Users/<name>/ instead of a real name.
EOF
}

# --- frontmatter --------------------------------------------------------------

# frontmatter_scope <ai dir> <repo-relative path> -> 0 for a markdown file
# under the aiDir outside ideas/ (its seed docs ship frontmatter-less).
frontmatter_scope() {
  case "$2" in
    *.md) ;;
    *) return 1 ;;
  esac
  case "$2" in
    "$1"/ideas/*) return 1 ;;
    "$1"/*) return 0 ;;
  esac
  return 1
}

# frontmatter_region <file> -> the part of the file an edit must touch to
# change its frontmatter: line 1 through the closing `---` when line 1 opens
# a fence (through the end when it never closes), else nothing. A doc with no
# fence has no region, so retitling its first line is not a frontmatter
# change (PR #274 review); adding or removing a fence is.
frontmatter_region() {
  [ -f "$1" ] || return 0
  awk 'NR == 1 { if ($0 !~ /^---[ \t\r]*$/) exit; print; next } { print } /^---[ \t\r]*$/ { exit }' "$1" 2>/dev/null
}

# frontmatter_issues <file> -> one issue per line; nothing when the
# frontmatter is valid. Frontmatter is a `---` fence on LINE 1 closed by the
# next `---` line, holding an identity field (any of title/name/topic/id/type,
# the framework's own templates) and a temporal one (any of updated/
# last_updated/created/started/date). The file is read directly: echoing it
# into grep -q/awk SIGPIPEs the writer past the 64 KiB pipe buffer, and
# under pipefail that read as "no frontmatter" (#33).
frontmatter_issues() {
  local file="$1" first fm closed=1
  first=$(head -n 1 "$file" | tr -d '\r')
  if ! grep -qE '^---' "$file"; then
    printf 'missing frontmatter block entirely\n'
    return 0
  fi
  if ! [[ "$first" =~ ^---[[:space:]]*$ ]]; then
    printf "frontmatter must start on line 1 with '---' (a '---' block further down is not frontmatter)\n"
    return 0
  fi
  fm=$(awk 'NR == 1 { next } /^---[ \t\r]*$/ { closed = 1; exit } { print } END { if (!closed) exit 3 }' "$file") || closed=0
  [ "$closed" = 1 ] || printf "frontmatter opened on line 1 is never closed with '---'\n"
  grep -qE '^(title|name|topic|id|type):' <<< "$fm" \
    || printf "missing identity field: one of 'title', 'name', 'topic', 'id', 'type'\n"
  grep -qE '^(updated|last_updated|created|started|date):' <<< "$fm" \
    || printf "missing temporal field: one of 'updated', 'last_updated', 'created', 'started', 'date'\n"
}

# frontmatter_reason <rel path> <issues> <ai dir> -> the reason.
frontmatter_reason() {
  local rel="$1" issues="$2" ai="$3" reason issue
  reason="Frontmatter issue in ${rel}:"
  while IFS= read -r issue; do
    [ -n "$issue" ] || continue
    reason="${reason}
  - ${issue}"
  done <<< "$issues"
  printf '%s\nFix the frontmatter before continuing (templates: %s/.templates/).\n' "$reason" "$ai"
}

# --- reuse audit --------------------------------------------------------------

REUSE_AUDIT_HEADING="Reuse audit"
# The per-file opt-out: `<!-- myspec:reuse-audit skip: <reason> -->` anywhere
# in the tech-spec counts as a skip decision for the whole document.
REUSE_AUDIT_MARKER_RE='<!--[[:space:]]*myspec:reuse-audit[[:space:]]+skip:'

# reuse_audit_scope <ai dir> <repo-relative path> -> 0 for a file named
# exactly tech-spec.md under <ai dir>/features/, a sub-feature's included.
# A plans/ tree holds dated copies, and `old-tech-spec.md` or a tech-spec.md
# outside the aiDir (src/features/...) is not a feature's tech-spec (#165).
reuse_audit_scope() {
  case "$2" in
    "$1"/features/*/plans/*) return 1 ;;
    "$1"/features/*/tech-spec.md) return 0 ;;
  esac
  return 1
}

# reuse_audit_state <file> -> the part of the file the gate reads: the
# `## Reuse audit` (or ###) section, heading through the line before the
# next heading of its level or higher, plus every marker line. Two files
# with the same state would get the same verdict, so an edit that leaves it
# unchanged is never judged.
reuse_audit_state() {
  local ln
  [ -f "$1" ] || return 0
  ln=$(_heading_lineno "$1" "$REUSE_AUDIT_HEADING")
  if [ -n "$ln" ]; then
    awk -v start="$ln" '
      NR == start { match($0, /^#+/); lvl = RLENGTH; print; next }
      NR > start { if ($0 ~ /^#+[ \t]/) { match($0, /^#+/); if (RLENGTH <= lvl) exit } print }' "$1" 2>/dev/null
  fi
  grep -E "$REUSE_AUDIT_MARKER_RE" "$1" 2>/dev/null || true
}

# reuse_audit_issues <file> -> the diagnostics, one per line; nothing when
# the file carries a skip marker with a reason or a valid section: the
# heading, a table after it with at least one data row, four cells per row,
# Decision in {reuse, skip}, a Reason on every skip row.
reuse_audit_issues() {
  local file="$1" marker reason out
  if marker=$(grep -m1 -E "$REUSE_AUDIT_MARKER_RE" "$file" 2>/dev/null); then
    reason=$(printf '%s' "$marker" | sed -E 's/.*myspec:reuse-audit[[:space:]]+skip:[[:space:]]*//; s/[[:space:]]*-->.*$//; s/[[:space:]]+$//')
    if [ -n "$reason" ]; then
      return 0
    fi
    printf 'the <!-- myspec:reuse-audit skip: ... --> marker needs a reason after "skip:"\n'
    return 0
  fi
  if ! out=$(assert_section_present "$file" "$REUSE_AUDIT_HEADING"); then
    printf '%s\n' "$out"
  elif ! out=$(assert_table_after_heading "$file" "$REUSE_AUDIT_HEADING" 1); then
    printf '%s\n' "$out"
  elif ! out=$(assert_reuse_audit_rows "$file" "$REUSE_AUDIT_HEADING"); then
    printf '%s\n' "$out"
  fi
}

# reuse_audit_reason <path> <diagnostics> -> the reason.
reuse_audit_reason() {
  cat <<EOF
BLOCKED: $1 is missing a valid "## Reuse audit" section.

Every tech-spec must enumerate reuse candidates from the shared surfaces of
this project (see the topology file named in .myspec.json, or the shared
library/utility directories) before introducing new code. Add a
"### Reuse audit" section with a table:

| Candidate | Surface | Decision | Reason |
|-----------|---------|----------|--------|
| {existing component} | {shared surface} | reuse | matches need in REQ-12 |
| {existing helper} | {shared surface} | skip | needs multi-step state |

Decision must be "reuse" or "skip"; every "skip" row needs a Reason.

Findings:
$2
To opt this tech-spec out, put <!-- myspec:reuse-audit skip: <reason> --> in it; that counts as a skip decision for the whole document. A tech-spec written before this gate is not re-checked: only its creation and an edit that touches the section are.
EOF
}
