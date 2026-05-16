#!/usr/bin/env bash
# no-absolute-paths.sh
# PostToolUse hook (Write|Edit matcher) — blocks any newly written content
# that contains absolute paths under $HOME, /Users/, or /home/, and the
# encoded-cwd literals derived from them.
#
# Policy: shared artifacts must be portable across machines and users. Use
# the placeholders `<repo_root>` and `<encoded_cwd>` (and the harness-fixed
# `~/.claude-personal/...` prefix). The companion helper at
# `lib/path-normalize.sh` exposes a `normalize_path` function that produces
# these forms.
#
# Output contract: emit `{"decision": "block", "reason": "..."}` to stderr
# (via the hook return JSON) when an offending path is found.

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

INPUT=$(cat)

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

[ -n "$FILE_PATH" ] || exit 0

# Resolve repo root (best effort)
REPO_ROOT=""
if R=$(git -C "$(dirname "$FILE_PATH")" rev-parse --show-toplevel 2>/dev/null); then
  REPO_ROOT="$R"
fi

# Allowlist — files that legitimately mention these path shapes (the regex
# detector itself, the helper that defines the placeholders, this hook).
# Compared on repo-relative path.
REL_PATH="$FILE_PATH"
if [ -n "$REPO_ROOT" ] && [ "${FILE_PATH#"$REPO_ROOT"/}" != "$FILE_PATH" ]; then
  REL_PATH="${FILE_PATH#"$REPO_ROOT"/}"
fi

case "$REL_PATH" in
  lib/path-normalize.sh|\
  plugins/myspec/lib/path-normalize.sh|\
  hooks/no-absolute-paths.sh|\
  plugins/myspec/hooks/no-absolute-paths.sh)
    exit 0
    ;;
esac

# Only inspect text-ish files we expect to ship. Skip binaries, lockfiles,
# anything in node_modules / .git / worktrees / build output.
case "$REL_PATH" in
  node_modules/*|.git/*|*/.git/*|.claude/worktrees/*|*/node_modules/*|dist/*|build/*|*.lock|*.png|*.jpg|*.jpeg|*.gif|*.pdf|*.zip|*.tar|*.tar.gz)
    exit 0
    ;;
esac

[ -f "$FILE_PATH" ] || exit 0

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

MATCHES=$(grep -noE "$DETECT_RE" "$FILE_PATH" 2>/dev/null | head -10 || true)

if [ -z "$MATCHES" ]; then
  exit 0
fi

# Build a remediation hint per match.
HINT=""
HOME_ESC="${HOME:-}"
while IFS= read -r line; do
  [ -n "$line" ] || continue
  LINENO_FOUND="${line%%:*}"
  REST="${line#*:}"
  MATCH="${REST}"
  # The absolute-form branch captures one leading boundary char via
  # (^|[^A-Za-z0-9._/-]) (grep ERE has no lookbehind). Strip it so the
  # downstream prefix logic + hint see a clean path. Encoded -Users-/-home-
  # forms and root-anchored matches start with - or / and are left as-is.
  case "$MATCH" in
    /*|-Users-*|-home-*) : ;;
    *) MATCH="${MATCH#?}" ;;
  esac
  SUGGESTION="use <repo_root>/<relative-path> for repo-internal paths, or ~/.claude-personal/projects/<encoded_cwd>/... for the harness memory dir"

  if [ -n "$REPO_ROOT" ]; then
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
  fi
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

  HINT="${HINT}  line ${LINENO_FOUND}: ${MATCH}
    → ${SUGGESTION}
"
done <<< "$MATCHES"

REASON=$(cat <<EOF
BLOCKED: ${FILE_PATH} contains absolute homedir paths. Shared artifacts must be portable across machines and users — use the placeholders <repo_root> and <encoded_cwd> (helper: lib/path-normalize.sh).

Findings:
${HINT}
If this file legitimately needs to describe these patterns (e.g. it teaches the encoding rule), add its repo-relative path to the allowlist in hooks/no-absolute-paths.sh.
EOF
)

# Emit a block decision. PostToolUse hooks can return a decision JSON; the
# harness surfaces the reason back to the agent.
printf '{"decision":"block","reason":%s}\n' "$(printf '%s' "$REASON" | jq -Rs .)"
exit 0
