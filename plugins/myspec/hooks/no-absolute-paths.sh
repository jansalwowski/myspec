#!/usr/bin/env bash
# no-absolute-paths.sh
# PostToolUse hook (Write|Edit|MultiEdit|NotebookEdit matcher). It runs after
# the write, so it cannot stop it: it flags a written file whose NEW content
# contains an absolute homedir path (/Users/<name>, /home/<name>) or the
# encoded-cwd literal derived from one, and asks the agent to fix it.
#
# Policy (framework-files/rules/paths.md): committed docs and framework files
# must be portable across machines and users. Use the placeholders
# `<repo_root>` and `<encoded_cwd>` (and the harness-fixed
# `~/.claude-personal/...` prefix). `.claude/lib/path-normalize.sh` exposes
# `normalize_path` and `encode_cwd`, which produce these forms.
#
# Scope (#163). The hook checks only what can leak into a shared artifact:
#   - files inside a git work tree and not gitignored there (scratch paths,
#     .claude/state/ session logs and build output are never committed);
#   - doc kinds anywhere (*.md, *.mdx, *.markdown, *.txt, *.rst, *.adoc), and
#     any file under .claude/, docs/ or the project aiDir (.myspec.json), the
#     trees the rule itself covers. App code, Dockerfiles and CI workflows
#     are out of scope: a route such as /home/Dashboard or a container path
#     such as /home/node/app is not a developer home directory;
#   - only the content the tool call added (Write content, Edit new_string,
#     MultiEdit edits[].new_string, NotebookEdit new_source), so an edit is
#     not flagged for a line it did not touch. A call carrying none of these
#     falls back to the whole file.
#
# Output contract: a PostToolUse decision JSON on stdout,
# `{"decision": "block", "reason": "..."}`, which the harness surfaces to the
# agent. Exit 0 always.

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

INPUT=$(cat)

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null || true)

[ -n "$FILE_PATH" ] || exit 0
[ -f "$FILE_PATH" ] || exit 0

# Resolve the file and its work tree physically, so a symlinked prefix
# (macOS /var -> /private/var) compares equal to what git reports.
FILE_DIR=$(cd "$(dirname "$FILE_PATH")" 2>/dev/null && pwd -P) || exit 0
REAL_PATH="$FILE_DIR/$(basename "$FILE_PATH")"

# Outside any work tree (a scratchpad, $TMPDIR): nothing there is committed.
REPO_ROOT=$(git -C "$FILE_DIR" rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$REPO_ROOT" ] || exit 0
REPO_ROOT=$(cd "$REPO_ROOT" 2>/dev/null && pwd -P) || exit 0

case "$REAL_PATH" in
  "$REPO_ROOT"/*) REL_PATH="${REAL_PATH#"$REPO_ROOT"/}" ;;
  *) exit 0 ;;
esac

case "$REL_PATH" in
  .git/*|*/.git/*) exit 0 ;;
esac

# Gitignored files never reach a commit (.claude/state/sessions/*.md).
if git -C "$REPO_ROOT" check-ignore -q -- "$REL_PATH" 2>/dev/null; then
  exit 0
fi

# Allowlist: files that define the detected path shapes themselves.
case "$REL_PATH" in
  lib/path-normalize.sh|\
  plugins/myspec/lib/path-normalize.sh|\
  hooks/no-absolute-paths.sh|\
  plugins/myspec/hooks/no-absolute-paths.sh|\
  .claude/hooks/no-absolute-paths.sh|\
  .claude/lib/path-normalize.sh)
    exit 0
    ;;
esac

# File kinds in scope: doc kinds anywhere, any kind under the rule's trees.
AI_DIR=""
if [ -f "$REPO_ROOT/.myspec.json" ]; then
  AI_DIR=$(jq -r '.aiDir // empty' "$REPO_ROOT/.myspec.json" 2>/dev/null || true)
  AI_DIR="${AI_DIR#./}"
  AI_DIR="${AI_DIR%/}"
  # No configured value: the documented default, as validate-frontmatter.sh
  # and verify-before-stop.sh resolve it. A repo without .myspec.json has no
  # aiDir at all, so only its doc kinds, .claude/ and docs/ are checked.
  [ -n "$AI_DIR" ] || AI_DIR=".ai"
fi

IN_SCOPE=0
case "$REL_PATH" in
  *.md|*.mdx|*.markdown|*.txt|*.rst|*.adoc|.claude/*|docs/*) IN_SCOPE=1 ;;
esac
if [ "$IN_SCOPE" -eq 0 ] && [ -n "$AI_DIR" ]; then
  case "$REL_PATH" in
    "$AI_DIR"/*) IN_SCOPE=1 ;;
  esac
fi
[ "$IN_SCOPE" -eq 1 ] || exit 0

# The content this call added. Write content maps line for line onto the
# file; for the other tools each finding is looked up in the file.
WHOLE_FILE=0
HAS_NEW=$(printf '%s' "$INPUT" | jq -r '
  .tool_input
  | if has("content") or has("new_string") or has("new_source") or has("edits") then "yes" else "no" end
' 2>/dev/null || echo no)

if [ "$HAS_NEW" = "yes" ]; then
  NEW_CONTENT=$(printf '%s' "$INPUT" | jq -r '
    .tool_input
    | [ .content, .new_string, .new_source, ((.edits // [])[] | .new_string) ]
    | map(select(type == "string"))
    | join("\n")
  ' 2>/dev/null || true)
  HAS_CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input | has("content")' 2>/dev/null || echo false)
  [ "$HAS_CONTENT" = "true" ] && WHOLE_FILE=1
else
  NEW_CONTENT=$(cat "$FILE_PATH")
  WHOLE_FILE=1
fi

[ -n "$NEW_CONTENT" ] || exit 0

# Detection patterns. The absolute forms (/Users, /home) must be at a path
# ROOT — preceded by start-of-line or a non-path character — so a relative
# sub-segment like `apps/web/src/components/home/HomeFoo.vue` (a `home/` dir
# followed by a Capitalized name) does NOT false-positive. grep ERE has no
# lookbehind, so the boundary is captured and stripped below.
#   /Users/<name>...        e.g. /Users/alice/work/foo   (root only)
#   /home/<name>...         e.g. /home/alice/work/foo     (root only)
#   -Users-<name>-...       encoded form of /Users/<name>/... (leading - kept)
#   -home-<name>-...        encoded form of /home/<name>/...   (leading - kept)
DETECT_RE='(^|[^A-Za-z0-9._/-])(/Users/[A-Za-z][A-Za-z0-9._-]*|/home/[A-Za-z][A-Za-z0-9._-]*)|(-Users-[A-Za-z][A-Za-z0-9._-]+|-home-[A-Za-z][A-Za-z0-9._-]+)'

# awk, not head: it reads all of grep's output, so no SIGPIPE under pipefail.
MATCHES=$(printf '%s\n' "$NEW_CONTENT" | grep -noE "$DETECT_RE" 2>/dev/null | awk 'NR <= 10' || true)

if [ -z "$MATCHES" ]; then
  exit 0
fi

# Build a remediation hint per match.
HINT=""
HOME_ESC="${HOME:-}"
while IFS= read -r line; do
  [ -n "$line" ] || continue
  LINE_FOUND="${line%%:*}"
  MATCH="${line#*:}"
  # The absolute-form branch captures one leading boundary char via
  # (^|[^A-Za-z0-9._/-]) (grep ERE has no lookbehind). Strip it so the
  # downstream prefix logic + hint see a clean path. Encoded -Users-/-home-
  # forms and root-anchored matches start with - or / and are left as-is.
  case "$MATCH" in
    /*|-Users-*|-home-*) : ;;
    *) MATCH="${MATCH#?}" ;;
  esac
  if [ "$WHOLE_FILE" -eq 0 ]; then
    LINE_FOUND=$(grep -nF -- "$MATCH" "$FILE_PATH" 2>/dev/null | awk -F: 'NR == 1 { print $1 }' || true)
    [ -n "$LINE_FOUND" ] || LINE_FOUND="?"
  fi
  SUGGESTION="use <repo_root>/<relative-path> for repo-internal paths, or ~/.claude-personal/projects/<encoded_cwd>/... for the harness memory dir"

  case "$MATCH" in
    "$REPO_ROOT"*)
      REL="${MATCH#"$REPO_ROOT"}"
      REL="${REL#/}"
      if [ -z "$REL" ]; then
        SUGGESTION="replace with <repo_root>"
      else
        SUGGESTION="replace with <repo_root>/$REL"
      fi
      ;;
  esac
  if [ -n "$HOME_ESC" ]; then
    case "$MATCH" in
      "$HOME_ESC"/.claude-personal/projects/*)
        REST_P="${MATCH#"$HOME_ESC"/.claude-personal/projects/}"
        FIRST="${REST_P%%/*}"
        TAIL=""
        if [ "$FIRST" != "$REST_P" ]; then
          TAIL="/${REST_P#"$FIRST"/}"
        fi
        SUGGESTION="replace with ~/.claude-personal/projects/<encoded_cwd>$TAIL"
        ;;
    esac
  fi

  HINT="${HINT}  line ${LINE_FOUND}: ${MATCH}
    → ${SUGGESTION}
"
done <<< "$MATCHES"

REASON=$(cat <<EOF
FIX NEEDED: ${REL_PATH} was written, but the new content contains absolute homedir paths. Committed docs and framework files must be portable across machines and users, so edit the file to use the placeholders <repo_root> and <encoded_cwd> (helper: .claude/lib/path-normalize.sh).

Findings:
${HINT}
Checked by .claude/hooks/no-absolute-paths.sh on doc files and on files under .claude/, docs/ or the aiDir that git does not ignore. To describe the pattern itself, write a placeholder such as /Users/<name>/ instead of a real name.
EOF
)

printf '{"decision":"block","reason":%s}\n' "$(printf '%s' "$REASON" | jq -Rs .)"
exit 0
