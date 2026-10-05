#!/usr/bin/env bash
# Regression fixture for validate-frontmatter.sh. One case per past fix:
#
#   8facc30  A doc over the 64 KiB pipe buffer was piped into `grep -q`; the
#            writer died of SIGPIPE and, under pipefail, a valid doc read as
#            "missing frontmatter block entirely". An empty `---`/`---` block
#            killed the hook silently under set -e. The block message printed
#            a literal ${aiDir} instead of the configured directory.
#   64b7f2c  The repo root came from the cwd, so a doc written in a linked
#            worktree (inside the main checkout) never matched the aiDir prefix
#            and was skipped.
#   4eb8ccb  Issues went to stdout with exit 0, which never reaches the agent;
#            the field check rejected the framework's own templates (topic/
#            started sessions, id/date memories, type indexes); the
#            frontmatter-less ideas/ seed docs were not exempt.
#   (doctor) `grep "^---"` matched anywhere and awk took the first `---`
#            block, so body text first and a later block holding title/updated
#            passed. Frontmatter must open on line 1.
#   #263     The hook rescanned the whole file after every edit, so a body
#            edit to a doc with broken frontmatter was blocked for a defect
#            it did not make. It now runs at PreToolUse on the proposed
#            content: a Write that creates the doc by its content, any
#            other Write or Edit only when it changes
#            the frontmatter region.
#
# Usage: validate-frontmatter-regression.test.sh [path-to-hook]

set -uo pipefail

HOOK="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../validate-frontmatter.sh}"
# The hooks find their lib through CLAUDE_PLUGIN_ROOT, as the harness exports it.
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$HOOK")/.." && pwd)}"

if [ ! -f "$HOOK" ]; then
  echo "FATAL: hook not found: $HOOK" >&2
  exit 1
fi

ROOT=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

REPO="$ROOT/main"
mkdir -p "$REPO"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
printf '{"aiDir":".ai"}\n' > "$REPO/.myspec.json"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m init

# run <cwd> <file> -> hook stdout for a Write that creates the file with its
# content (the fixture on disk stands in for the proposed content, and is
# moved aside while the hook runs); exit status in $RC
run() {
  local payload
  payload=$(jq -nc --arg c "$1" --arg f "$2" --rawfile body "$2" '{cwd: $c, tool_name: "Write", tool_input: {file_path: $f, content: $body}}')
  mv "$2" "$2.fixture"
  OUT=$(printf '%s' "$payload" | bash "$HOOK" 2>/dev/null)
  RC=$?
  mv "$2.fixture" "$2"
}

# rewrite <cwd> <file> <content> -> hook stdout for a Write over the file on disk
rewrite() {
  OUT=$(jq -nc --arg c "$1" --arg f "$2" --arg b "$3" '{cwd: $c, tool_name: "Write", tool_input: {file_path: $f, content: $b}}' \
    | bash "$HOOK" 2>/dev/null)
  RC=$?
}

# edit <cwd> <file> <old> <new> -> hook stdout for an Edit of the file on disk
edit() {
  OUT=$(jq -nc --arg c "$1" --arg f "$2" --arg o "$3" --arg n "$4" '{cwd: $c, tool_name: "Edit", tool_input: {file_path: $f, old_string: $o, new_string: $n}}' \
    | bash "$HOOK" 2>/dev/null)
  RC=$?
}

reason()   { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null; }

expect_block() {  # expect_block <desc>: the PreToolUse deny alone, no legacy decision/reason pair (3.0 host floor)
  if [ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | jq -r 'has("decision") or has("reason")' 2>/dev/null)" = false ] \
      && [ "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = deny ]; then ok; else fail "$1 (exit $RC, output: ${OUT:0:200})"; fi
}
expect_quiet() {  # expect_quiet <desc>: exit 0 and no output
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok; else fail "$1 (exit $RC, output: ${OUT:0:200})"; fi
}

# big_body <file>: appends ~256 KiB of prose, well past any pipe buffer
big_body() {
  local line
  line=$(printf 'lorem ipsum dolor sit amet %.0s' 1 2 3 4 5 6 7 8)
  for _ in $(seq 1 1200); do printf '%s\n' "$line"; done >> "$1"
}

mkdir -p "$REPO/.ai/features/x"

# --- 8facc30: large docs --------------------------------------------------------
F="$REPO/.ai/features/x/big-valid.md"
printf -- '---\ntitle: Big\nupdated: 2026-01-01\n---\n' > "$F"
big_body "$F"
[ "$(wc -c < "$F")" -gt 131072 ] && ok || fail "fixture: big doc exceeds 128 KiB"
run "$REPO" "$F"
expect_quiet "a >64 KiB doc with valid frontmatter passes (SIGPIPE false block)"

F="$REPO/.ai/features/x/big-none.md"
: > "$F"
big_body "$F"
run "$REPO" "$F"
expect_block "a >64 KiB doc with no frontmatter still blocks"
reason | grep -q 'missing frontmatter block entirely' && ok || fail "the big-doc block names the missing block"

# --- 8facc30: empty frontmatter block ------------------------------------------
F="$REPO/.ai/features/x/empty-block.md"
printf -- '---\n---\nbody\n' > "$F"
run "$REPO" "$F"
expect_block "an empty ---/--- block blocks instead of dying under set -e"
reason | grep -q 'missing identity field' && ok || fail "the empty block reports the missing identity field"
reason | grep -q 'missing temporal field' && ok || fail "the empty block reports the missing temporal field"

# --- 8facc30: the message names the configured aiDir ---------------------------
REPO2="$ROOT/custom"
mkdir -p "$REPO2/docs/ai/features/y"
git init -q -b main "$REPO2"
printf '{"aiDir":"docs/ai"}\n' > "$REPO2/.myspec.json"
printf 'no frontmatter\n' > "$REPO2/docs/ai/features/y/spec.md"
run "$REPO2" "$REPO2/docs/ai/features/y/spec.md"
expect_block "a doc under a custom aiDir is validated"
reason | grep -qF 'docs/ai/.templates/' && ok || fail "the block names the resolved aiDir (got: $(reason | tail -1))"
# shellcheck disable=SC2016 # literal text, not an expansion
reason | grep -qF '${aiDir}' && fail "the block does not print a literal \${aiDir}" || ok

# --- 64b7f2c: a doc written in a linked worktree, cwd on the main checkout ------
WT="$REPO/.claude/worktrees/wt"
git -C "$REPO" worktree add -q -b wt "$WT" main
mkdir -p "$WT/.ai/features/x"
printf 'no frontmatter\n' > "$WT/.ai/features/x/spec.md"
run "$REPO" "$WT/.ai/features/x/spec.md"
expect_block "a worktree doc is validated when the cwd is the main checkout"
reason | grep -qF 'Frontmatter issue in .ai/features/x/spec.md' && ok \
  || fail "the worktree doc is reported relative to its own root (got: $(reason | head -1))"

# --- 4eb8ccb: feedback is a block decision, not plain stdout -------------------
F="$REPO/.ai/features/x/no-fm.md"
printf '# Title\n\nbody\n' > "$F"
run "$REPO" "$F"
expect_block "a doc without frontmatter emits a block-decision JSON"

# --- 4eb8ccb: the framework's own template field sets pass ---------------------
mkdir -p "$REPO/.ai/memory/sessions/archive" "$REPO/.ai/memory/episodic"
F="$REPO/.ai/memory/sessions/archive/s.md"
printf -- '---\ntopic: a session\nstarted: 2026-01-01\n---\nbody\n' > "$F"
run "$REPO" "$F"
expect_quiet "session frontmatter (topic/started) passes"

F="$REPO/.ai/memory/episodic/e.md"
printf -- '---\nid: EP-001\ndate: 2026-01-01\n---\nbody\n' > "$F"
run "$REPO" "$F"
expect_quiet "memory frontmatter (id/date) passes"

F="$REPO/.ai/memory/index.md"
printf -- '---\ntype: index\nupdated: 2026-01-01\n---\nbody\n' > "$F"
run "$REPO" "$F"
expect_quiet "type-index frontmatter (type/updated) passes"

# --- (doctor): frontmatter must open on line 1 ---------------------------------
F="$REPO/.ai/features/x/late-block.md"
printf -- '# Title\n\nbody first\n\n---\ntitle: Late\nupdated: 2026-01-01\n---\n' > "$F"
run "$REPO" "$F"
expect_block "a --- block after body text is not frontmatter"
reason | grep -q 'line 1' && ok || fail "the block says frontmatter must start on line 1 (got: $(reason | head -2))"

F="$REPO/.ai/features/x/unclosed.md"
printf -- '---\ntitle: Open\nupdated: 2026-01-01\nbody with no closing fence\n' > "$F"
run "$REPO" "$F"
expect_block "a frontmatter fence that never closes blocks"

F="$REPO/.ai/features/x/crlf.md"
printf -- '---\r\ntitle: Win\r\nupdated: 2026-01-01\r\n---\r\nbody\r\n' > "$F"
run "$REPO" "$F"
expect_quiet "CRLF frontmatter on line 1 passes"

# --- #263: the proposed content is judged, never the file on disk --------------
F="$REPO/.ai/features/x/new-doc.md"
rm -f "$F"
OUT=$(jq -nc --arg c "$REPO" --arg f "$F" '{cwd: $c, tool_name: "Write", tool_input: {file_path: $f, content: "# No frontmatter\n\nbody\n"}}' | bash "$HOOK" 2>/dev/null); RC=$?
expect_block "a Write is judged by its content before the file exists"
[ ! -e "$F" ] && ok || fail "the hook creates nothing"

F="$REPO/.ai/features/x/body-only.md"
printf '# Title\n\nold body\n' > "$F"
edit "$REPO" "$F" "old body" "new body"
expect_quiet "a body edit to a doc without frontmatter is not blocked for the missing frontmatter (regression #263)"

F="$REPO/.ai/features/x/good.md"
printf -- '---\ntitle: Good\nupdated: 2026-01-01\n---\nbody\n' > "$F"
edit "$REPO" "$F" "body" "more body"
expect_quiet "a body edit to a valid doc passes"
edit "$REPO" "$F" "title: Good" "titel: Good"
expect_block "an edit that breaks the frontmatter is denied"
reason | grep -q 'missing identity field' && ok || fail "the edit's deny names the field it removed"
edit "$REPO" "$F" "updated: 2026-01-01" "updated: 2026-02-02"
expect_quiet "an edit that keeps the frontmatter valid passes"
edit "$REPO" "$F" "nowhere in the file" "x"
expect_quiet "an edit whose old_string the file does not hold changes nothing and passes"

F="$REPO/.ai/features/x/body-only.md"
edit "$REPO" "$F" "# Title" "# Title 2"
expect_quiet "retitling line 1 of a doc without a fence is not a frontmatter change (PR #274 review)"
edit "$REPO" "$F" "# Title" $'---\ntitle: Added\nupdated: 2026-01-01\n---\n# Title'
expect_quiet "an edit that adds valid frontmatter to a doc without one passes"
edit "$REPO" "$F" "# Title" $'---\ntitle: Added\n---\n# Title'
expect_block "an edit that adds incomplete frontmatter is denied"

OUT=$(jq -nc --arg c "$REPO" --arg f "$F" '{cwd: $c, tool_name: "MultiEdit", tool_input: {file_path: $f, edits: [{old_string: "old body", new_string: "body 2"}, {old_string: "# Title", new_string: "---\ntitle: Multi\n---\n# Title"}]}}' | bash "$HOOK" 2>/dev/null); RC=$?
expect_block "a MultiEdit is judged by the content all its edits leave"
reason | grep -q 'missing temporal field' && ok || fail "the MultiEdit deny names the missing field"

# A Write over an existing doc is compared like an edit (PR #274 review): a
# body rewrite that keeps an already-broken header adds no defect.
F="$REPO/.ai/features/x/broken.md"
printf -- '---\ntitle: X\n---\nbody\n' > "$F"
rewrite "$REPO" "$F" $'---\ntitle: X\n---\nbody 2\n'
expect_quiet "a Write that keeps a broken header and rewrites the body passes"
rewrite "$REPO" "$F" $'---\ntitel: X\n---\nbody 2\n'
expect_block "a Write that changes the broken header and leaves it broken is denied"
rewrite "$REPO" "$F" $'---\ntitle: X\nupdated: 2026-01-01\n---\nbody 2\n'
expect_quiet "a Write that fixes the header passes"
F="$REPO/.ai/features/x/fenced.md"
printf -- '---\ntitle: F\nupdated: 2026-01-01\n---\nbody\n' > "$F"
edit "$REPO" "$F" $'---\ntitle: F\nupdated: 2026-01-01\n---\n' ""
expect_block "an edit that removes the fence is a frontmatter change"

# --- 4eb8ccb: ideas/ seed docs are exempt --------------------------------------
mkdir -p "$REPO/.ai/ideas"
F="$REPO/.ai/ideas/PRIORITY-LISTING.md"
printf '# Priority listing\n' > "$F"
run "$REPO" "$F"
expect_quiet "a frontmatter-less ideas/ seed doc is exempt"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
