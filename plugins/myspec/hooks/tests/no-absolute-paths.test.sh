#!/usr/bin/env bash
# Regression fixture for no-absolute-paths.sh (#163, #210 items 6 and 9).
#
# The hook exists to stop a developer's absolute home paths leaking into
# committed docs and framework files, so those writes must still be flagged.
# What it must leave alone: gitignored files (.claude/state/sessions/), files
# outside any repository (scratch paths), lines an Edit did not touch, app
# code such as a /home/Dashboard route, and container paths such as a
# Dockerfile WORKDIR /home/node/app. Its message must name the helper by the
# path that runs it, the plugin's lib/ (CLAUDE_PLUGIN_ROOT), not a copy under
# the project's .claude/.
#
# Usage: no-absolute-paths.test.sh [path-to-hook]

set -uo pipefail

HOOK="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../no-absolute-paths.sh}"
# The hooks find their lib through CLAUDE_PLUGIN_ROOT, as the harness exports it.
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$HOOK")/.." && pwd)}"

if [ ! -x "$HOOK" ]; then
  echo "FATAL: hook not executable: $HOOK" >&2
  exit 1
fi

ROOT=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/batchP-nap.XXXXXX")" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT

REPO="$ROOT/repo"
mkdir -p "$REPO"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
printf '{"aiDir":".ai","frameworkVersion":"2.0.0"}\n' > "$REPO/.myspec.json"
printf '.claude/state/\n.claude/worktrees/\n' > "$REPO/.gitignore"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m init

LEAK="/Users/alice/work/proj/src/a.ts"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

OUT=""
run() {  # run <json>
  OUT=$(printf '%s' "$1" | bash "$HOOK" 2>/dev/null)
}

j() { printf '%s' "$1" | jq -Rs .; }

write_call() {  # write_call <path> <content>: put the file on disk, then run the hook as PostToolUse
  mkdir -p "$(dirname "$1")"
  printf '%s' "$2" > "$1"
  run "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":$(j "$1"),\"content\":$(j "$2")}}"
}

edit_call() {  # edit_call <path> <new_string>: the file already holds the edited content
  run "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":$(j "$1"),\"old_string\":\"x\",\"new_string\":$(j "$2")}}"
}

expect_flag() {
  if printf '%s' "$OUT" | jq -e '.decision == "block"' >/dev/null 2>&1; then ok; else fail "$1 (not flagged)"; fi
}
expect_quiet() {
  if [ -z "$OUT" ]; then ok; else fail "$1 (flagged: $(printf '%s' "$OUT" | head -c 160))"; fi
}
expect_reason() {  # expect_reason <fixed-string> <desc>
  if printf '%s' "$OUT" | jq -r '.reason' 2>/dev/null | grep -qF -- "$1"; then ok; else fail "$2 (reason lacks: $1)"; fi
}
expect_no_reason() {
  if printf '%s' "$OUT" | jq -r '.reason' 2>/dev/null | grep -qF -- "$1"; then fail "$2 (reason has: $1)"; else ok; fi
}

# --- still flagged: the leaks the hook exists for -------------------------

write_call "$REPO/.ai/features/foo/spec.md" "# Spec
See $LEAK for the entry point.
"
expect_flag "aiDir doc with a homedir path"
expect_reason "line 2: /Users/alice" "Write reports the file line"
expect_reason "contains absolute homedir paths" "friction-scan signature kept"
expect_reason "no-absolute-paths.sh" "message names the hook"
expect_reason "$CLAUDE_PLUGIN_ROOT/lib/path-normalize.sh" "message cites the helper under the plugin's lib/"
expect_no_reason ".claude/lib/" "message does not point at a project-local lib copy"
expect_no_reason "add its repo-relative path to the allowlist" "message does not ask adopters to edit a framework-owned hook"
expect_no_reason "BLOCKED" "PostToolUse message does not claim the write was blocked"

write_call "$REPO/README.md" "Run from /home/bob/checkout."
expect_flag "root README with a /home path"

write_call "$REPO/.ai/features/foo/seed.json" "{\"p\":\"$LEAK\"}"
expect_flag "non-doc file under the aiDir"

write_call "$REPO/.claude/hooks/custom.sh" "cd $LEAK"
expect_flag "non-doc file under .claude/"

write_call "$REPO/docs/notes.html" "<p>$LEAK</p>"
expect_flag "non-doc file under docs/"

write_call "$REPO/CLAUDE.md" "Memory: ~/.claude-personal/projects/-Users-alice-work-proj/memory"
expect_flag "encoded-cwd literal in a doc"

printf 'intro\nclean line\nnow %s\n' "$LEAK" > "$REPO/docs/edit.md"
edit_call "$REPO/docs/edit.md" "now $LEAK"
expect_flag "Edit whose new_string adds a homedir path"
expect_reason "line 3: /Users/alice" "Edit finding points at the file line"

printf 'a\n%s\n' "$LEAK" > "$REPO/docs/multi.md"
run "{\"tool_name\":\"MultiEdit\",\"tool_input\":{\"file_path\":$(j "$REPO/docs/multi.md"),\"edits\":[{\"old_string\":\"x\",\"new_string\":\"a\"},{\"old_string\":\"y\",\"new_string\":$(j "$LEAK")}]}}"
expect_flag "MultiEdit with one dirty edit"

printf '%s\n' "$LEAK" > "$REPO/docs/nocontent.md"
run "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":$(j "$REPO/docs/nocontent.md")}}"
expect_flag "call without new content falls back to the whole file"

# #210 item 6: a file in a real linked worktree under .claude/worktrees/ is
# that worktree's own committed content, so it is checked like any other.
git -C "$REPO" worktree add -q -b wt1 "$REPO/.claude/worktrees/wt1" 2>/dev/null
write_call "$REPO/.claude/worktrees/wt1/doc.md" "$LEAK"
expect_flag "doc in a real linked worktree under .claude/worktrees/"

# --- not flagged ----------------------------------------------------------

write_call "$REPO/.claude/state/sessions/s1.md" "cwd: $LEAK"
expect_quiet "gitignored session log"

mkdir -p "$ROOT/norepo"
write_call "$ROOT/norepo/a.md" "$LEAK"
expect_quiet "file outside any repository"

printf '%s\nclean line\n' "$LEAK" > "$REPO/docs/untouched.md"
edit_call "$REPO/docs/untouched.md" "clean line"
expect_quiet "Edit with a clean new_string on a file with an old leak"

write_call "$REPO/app/r.ts" "router.push('/home/Dashboard')"
expect_quiet "app route string in source code"

write_call "$REPO/Dockerfile" "FROM node
WORKDIR /home/node/app
"
expect_quiet "Dockerfile container path"

write_call "$REPO/.github/workflows/ci.yml" "run: cd /home/runner/work"
expect_quiet "CI workflow runner path"

write_call "$REPO/.ai/features/foo/tech-spec.md" "Use <repo_root>/src or /Users/<name>/ in examples."
expect_quiet "placeholder forms in a doc"

write_call "$REPO/docs/rel.md" "See apps/web/src/components/home/HomeFoo.vue"
expect_quiet "relative home/ segment"

# --- aiDir default: .myspec.json without aiDir means .ai ------------------

new_repo() {  # new_repo <dir> [myspec.json content]: an initialised repo
  mkdir -p "$1"
  git init -q -b main "$1"
  [ "$#" -lt 2 ] || printf '%s\n' "$2" > "$1/.myspec.json"
}

NOAIDIR="$ROOT/noaidir"
new_repo "$NOAIDIR" '{}'
write_call "$NOAIDIR/.ai/index.yaml" "a: /Users/alice/x"
expect_flag "non-doc file under the default .ai when .myspec.json has no aiDir"

NOCONFIG="$ROOT/noconfig"
new_repo "$NOCONFIG"
write_call "$NOCONFIG/.ai/index.yaml" "a: /Users/alice/x"
expect_quiet "repo without .myspec.json has no aiDir tree in scope"

TOTAL=$((PASS + FAIL))
printf 'no-absolute-paths: %d/%d passed\n' "$PASS" "$TOTAL"
[ "$FAIL" -eq 0 ]
