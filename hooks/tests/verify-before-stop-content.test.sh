#!/usr/bin/env bash
# End-to-end fixture for the Stop gate's content checks (R14, #263): the
# catch-all for writes the PreToolUse content gates never see. A Bash
# heredoc, `sed -i` or `tee` is recorded by mark-code-changed.sh as a write,
# and at Stop lib/stop-gate/content.sh runs the three checks over the lines
# such a write added: absolute homedir paths (in the files paths.md covers),
# frontmatter (a ${aiDir} doc the session created, or whose frontmatter it
# changed) and the reuse audit (a tech-spec the session created). What it
# must leave alone: a leak that was already in HEAD on a line the session did
# not add, a tech-spec that predates the session, a file git does not report
# changed, a gitignored file, and another session's writes.
#
# Usage: verify-before-stop-content.test.sh [path-to-stop-hook]

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="${1:-$HERE/../verify-before-stop.sh}"
MARK="$HERE/../mark-code-changed.sh"
# The hooks find their lib through CLAUDE_PLUGIN_ROOT, as the harness exports it.
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$HOOK")/.." && pwd)}"

ROOT=$(cd "$(mktemp -d)" && pwd -P)
SID="vbsc-$$"
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

LEAK="/Users/alice/work/proj/src/a.ts"

REPO="$ROOT/repo"
mkdir -p "$REPO/.ai/features/old" "$REPO/docs"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
printf '{"aiDir":".ai","frameworkVersion":"3.0.0"}\n' > "$REPO/.myspec.json"
printf '.claude/state/\n' > "$REPO/.gitignore"
# A pre-hook tech-spec without a reuse audit, and a doc with an old leak.
printf -- '---\ntitle: Old\ncreated: 2026-01-01\n---\n\n### Architecture\nold\n\n### Steps\n1. one\n' > "$REPO/.ai/features/old/tech-spec.md"
printf -- '---\ntitle: Notes\nupdated: 2026-01-01\n---\nold leak: %s\nclean line\n' "$LEAK" > "$REPO/docs/notes.md"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m init

# bashcmd <sid-suffix> <command>: runs the command in the repo, then records
# it the way the harness does (PostToolUse Bash through mark-code-changed.sh).
bashcmd() {
  (cd "$REPO" && eval "$2") >/dev/null 2>&1
  jq -nc --arg s "$SID-$1" --arg c "$REPO" --arg cmd "$2" '{session_id: $s, tool_name: "Bash", cwd: $c, tool_input: {command: $cmd}}' \
    | bash "$MARK" >/dev/null 2>&1
}

# stop <sid-suffix> -> hook stdout
stop() {
  jq -nc --arg s "$SID-$1" --arg c "$REPO" '{session_id: $s, cwd: $c}' | bash "$HOOK" 2>/dev/null
}

decision() { printf '%s' "$1" | jq -r '.decision // "none"' 2>/dev/null || printf 'not-json'; }
reason()   { printf '%s' "$1" | jq -r '.reason // ""' 2>/dev/null; }
expect_in() {  # expect_in <needle> <haystack> <desc>
  case "$2" in *"$1"*) ok ;; *) fail "$3 (no '$1' in: ${2:0:300})" ;; esac
}
expect_not_in() {
  case "$2" in *"$1"*) fail "$3 (found '$1')" ;; *) ok ;; esac
}

# --- a clean session approves -------------------------------------------------
bashcmd 0 "printf 'see src/a.ts\n' >> docs/notes.md"
OUT=$(stop 0)
[ "$(decision "$OUT")" = approve ] && ok || fail "a clean heredoc append approves (got: ${OUT:0:200})"

# --- a heredoc write leaking a homedir path blocks at Stop --------------------
bashcmd 1 "cat > docs/leak.md <<'EOF'
# Leak
intro
see $LEAK
EOF"
OUT=$(stop 1)
[ "$(decision "$OUT")" = block ] && ok || fail "a heredoc leak blocks the stop (got: ${OUT:0:200})"
R=$(reason "$OUT")
expect_in "Content checks failed for files this session wrote" "$R" "the block says what it checked"
expect_in "lines this session added to docs/leak.md contains absolute homedir paths" "$R" "the block names the file with the hook's reason"
expect_in "line 3: /Users/alice" "$R" "the block names the file line"
expect_in "no-absolute-paths.sh" "$R" "the block names the hook whose rule it is"

# --- only the lines the session added count ------------------------------------
rm -f "$REPO/docs/leak.md"
bashcmd 2 "sed -i.bak 's/clean line/clean line, edited/' docs/notes.md && rm -f docs/notes.md.bak"
OUT=$(stop 2)
[ "$(decision "$OUT")" = approve ] && ok || fail "a sed -i edit beside an old leak approves (got: ${OUT:0:300})"

bashcmd 3 "sed -i.bak 's#clean line#clean line $LEAK#' docs/notes.md && rm -f docs/notes.md.bak"
OUT=$(stop 3)
[ "$(decision "$OUT")" = block ] && ok || fail "a sed -i edit that adds a leak blocks (got: ${OUT:0:200})"
R=$(reason "$OUT")
expect_in "line 6: /Users/alice" "$R" "the block names the edited line, not the old leak's"
expect_not_in "line 5:" "$R" "the old leak on an untouched line is not reported"
git -C "$REPO" checkout -q -- docs/notes.md

# --- a file outside the rule's scope is not checked ----------------------------
bashcmd 4 "printf 'WORKDIR /home/node/app\n' > Dockerfile"
OUT=$(stop 4)
[ "$(decision "$OUT")" = approve ] && ok || fail "a Bash write of a container path to a Dockerfile approves (got: ${OUT:0:200})"
rm -f "$REPO/Dockerfile"

bashcmd 5 "mkdir -p .claude/state && printf 'cwd: $LEAK\n' > .claude/state/scratch.md"
OUT=$(stop 5)
[ "$(decision "$OUT")" = approve ] && ok || fail "a gitignored file is not checked (got: ${OUT:0:200})"

# --- frontmatter: a doc the session created, or whose frontmatter it changed ----
bashcmd 6 "cat > .ai/features/old/plan.md <<'EOF'
# Plan
no frontmatter
EOF"
OUT=$(stop 6)
[ "$(decision "$OUT")" = block ] && ok || fail "a heredoc-created aiDir doc without frontmatter blocks (got: ${OUT:0:200})"
R=$(reason "$OUT")
expect_in "Frontmatter issue in .ai/features/old/plan.md" "$R" "the block carries the frontmatter hook's reason"
expect_in "missing frontmatter block entirely" "$R" "the block names the issue"
rm -f "$REPO/.ai/features/old/plan.md"

bashcmd 7 "printf '\nmore body\n' >> .ai/features/old/tech-spec.md"
OUT=$(stop 7)
[ "$(decision "$OUT")" = approve ] && ok || fail "a body append to a tracked doc with valid frontmatter approves (got: ${OUT:0:300})"
git -C "$REPO" checkout -q -- .ai/features/old/tech-spec.md

bashcmd 8 "sed -i.bak 's/^created: 2026-01-01$/createdd: x/' .ai/features/old/tech-spec.md && rm -f .ai/features/old/tech-spec.md.bak"
OUT=$(stop 8)
[ "$(decision "$OUT")" = block ] && ok || fail "a sed -i that breaks a tracked doc's frontmatter blocks (got: ${OUT:0:200})"
expect_in "missing temporal field" "$(reason "$OUT")" "the block names the broken field"
git -C "$REPO" checkout -q -- .ai/features/old/tech-spec.md

# --- reuse audit: only a tech-spec the session created ------------------------
bashcmd 9 "sed -i.bak 's/^old$/old, edited/' .ai/features/old/tech-spec.md && rm -f .ai/features/old/tech-spec.md.bak"
OUT=$(stop 9)
[ "$(decision "$OUT")" = approve ] && ok || fail "an edit to a pre-hook tech-spec without a reuse audit approves (regression #263; got: ${OUT:0:300})"
git -C "$REPO" checkout -q -- .ai/features/old/tech-spec.md

bashcmd 10 "mkdir -p .ai/features/new && cat > .ai/features/new/tech-spec.md <<'EOF'
---
title: New
created: 2026-01-01
---

### Architecture
fresh
EOF"
OUT=$(stop 10)
[ "$(decision "$OUT")" = block ] && ok || fail "a heredoc-created tech-spec without a reuse audit blocks (got: ${OUT:0:200})"
R=$(reason "$OUT")
expect_in '.ai/features/new/tech-spec.md is missing a valid "## Reuse audit" section' "$R" "the block carries the reuse-audit hook's reason"
expect_in "myspec:reuse-audit skip:" "$R" "the block names the per-file marker"

bashcmd 11 "printf '\n<!-- myspec:reuse-audit skip: greenfield, nothing shared yet -->\n' >> .ai/features/new/tech-spec.md"
OUT=$(stop 11)
[ "$(decision "$OUT")" = approve ] && ok || fail "the marker added by a Bash write satisfies the gate at Stop (got: ${OUT:0:300})"

# A tech-spec created and committed in the session is in HEAD, so Stop
# treats it as pre-existing; the PreToolUse hook is the gate for a Write.
git -C "$REPO" add -A && git -C "$REPO" commit -q -m new
bashcmd 12 "sed -i.bak 's/^fresh$/fresh, edited/' .ai/features/new/tech-spec.md && rm -f .ai/features/new/tech-spec.md.bak"
OUT=$(stop 12)
[ "$(decision "$OUT")" = approve ] && ok || fail "a committed tech-spec is not re-checked by an edit elsewhere (got: ${OUT:0:300})"
git -C "$REPO" checkout -q -- .

# --- a session's writes are its own ----------------------------------------------
bashcmd 13 "cat > docs/other.md <<'EOF'
see $LEAK
EOF"
OUT=$(stop 14)
[ "$(decision "$OUT")" = approve ] && ok || fail "another session's leak does not block this session (got: ${OUT:0:200})"
OUT=$(stop 13)
[ "$(decision "$OUT")" = block ] && ok || fail "the session that wrote the leak is blocked (got: ${OUT:0:200})"
rm -f "$REPO/docs/other.md"

# --- the continuation after a block is approved (R10) -----------------------------
bashcmd 15 "printf 'see $LEAK\n' > docs/again.md"
OUT=$(jq -nc --arg s "$SID-15" --arg c "$REPO" '{session_id: $s, cwd: $c, stop_hook_active: true}' | bash "$HOOK" 2>/dev/null)
[ "$(decision "$OUT")" = approve ] && ok || fail "stop_hook_active approves without re-running the content checks"
rm -f "$REPO/docs/again.md"

# --- a project without verification.json still gets the content checks ------------
[ ! -f "$REPO/.claude/verification.json" ] && ok || fail "fixture: no verification.json"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
