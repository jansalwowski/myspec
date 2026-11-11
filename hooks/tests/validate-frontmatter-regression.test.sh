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
#   #357     The report templates feature-implement and feature-implement-review
#            ship (holistic-review.md, conformance-report.md) carried feature/
#            reviewed, neither an identity nor a temporal field, so every run
#            that persisted one was blocked by this hook.
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

# --- #357: the report frontmatter myspec's own skills ship passes ---------------
# The templates under test are this checkout's, wherever CLAUDE_PLUGIN_ROOT points.
SKILLS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/skills"
mkdir -p "$REPO/.ai/features/x"
for tpl in feature-implement/holistic-reviewer-prompt.md:holistic-review.md \
           feature-implement-review/SKILL.md:conformance-report.md; do
  src="$SKILLS/${tpl%%:*}"
  F="$REPO/.ai/features/x/${tpl##*:}"
  # The first ```yaml block holding head_sha is the persisted report's frontmatter.
  awk '/^```yaml$/ { inb=1; buf=""; next }
       inb && /^```$/ { if (buf ~ /head_sha:/) { printf "%s", buf; exit } inb=0; next }
       inb { buf = buf $0 "\n" }' "$src" > "$F"
  if grep -q '^head_sha:' "$F"; then
    run "$REPO" "$F"
    expect_quiet "the ${tpl##*:} template frontmatter passes"
  else
    fail "no report frontmatter block found in ${tpl%%:*}"
  fi
done

# --- 4eb8ccb: ideas/ seed docs are exempt --------------------------------------
mkdir -p "$REPO/.ai/ideas"
F="$REPO/.ai/ideas/PRIORITY-LISTING.md"
printf '# Priority listing\n' > "$F"
run "$REPO" "$F"
expect_quiet "a frontmatter-less ideas/ seed doc is exempt"

# --- the pre-filter: a call that cannot concern the hook starts no process -----
# The hook runs on every Write and Edit, and only a path ending in .md can be
# its business. The raw payload is matched with a builtin before jq starts or
# a lib is sourced. Observed through a jq on PATH that logs each start. The
# filter must never skip what the full check would deny, so each payload shape
# that hides the ending from a raw match is shown to reach the check: the
# payloads are written by hand, as jq would not escape them this way.
SHIM="$ROOT/shim"
JQ_LOG="$ROOT/jq.log"
mkdir -p "$SHIM"
printf '#!/bin/sh\necho jq >> "%s"\nexec "%s" "$@"\n' "$JQ_LOG" "$(command -v jq)" > "$SHIM/jq"
chmod +x "$SHIM/jq"
raw() {  # raw <json> -> OUT, RC for the payload exactly as given; JQ_RUNS, how often the hook started jq
  : > "$JQ_LOG"
  OUT=$(printf '%s' "$1" | PATH="$SHIM:$PATH" bash "$HOOK" 2>/dev/null); RC=$?
  JQ_RUNS=$(wc -l < "$JQ_LOG" | tr -d ' ')
}
no_jq() { [ "$JQ_RUNS" -eq 0 ] && ok || fail "$1 (jq started $JQ_RUNS times)"; }
DOC="$REPO/.ai/features/x/pre-filter.md"
rm -f "$DOC"
raw "{\"cwd\":\"$REPO\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$REPO/src/a.ts\",\"content\":\"export const a = 1;\\n\"}}"
expect_quiet "a source write passes"
no_jq "a source write exits before jq starts"
raw "{\"cwd\":\"$REPO\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$REPO/src/a.ts\",\"old_string\":\"1\",\"new_string\":\"2\"}}"
no_jq "a source edit exits before jq starts"
# The control: the same shape with a doc path reaches the check, and the log sees it.
raw "{\"cwd\":\"$REPO\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$DOC\",\"content\":\"no frontmatter\\n\"}}"
expect_block "a doc write with no frontmatter is still denied"
[ "$JQ_RUNS" -gt 0 ] && ok || fail "the jq log sees the full check run"
raw "{\"cwd\":\"$REPO\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"${DOC//\//\\/}\",\"content\":\"no frontmatter\\n\"}}"
expect_block "a path with escaped slashes (\\/) is still denied"
raw "{\"cwd\":\"$REPO\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"${DOC%.md}.\\u006dd\",\"content\":\"no frontmatter\\n\"}}"
expect_block "a path whose extension carries a unicode escape (.\\u006dd) is still denied"
raw "{\"cwd\":\"$REPO\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"${DOC%.md}\\u002emd\",\"content\":\"no frontmatter\\n\"}}"
expect_block "a path whose dot is a unicode escape (\\u002emd) is still denied"
# payload_parse strips trailing newlines from the path, so the full check sees a doc.
raw "{\"cwd\":\"$REPO\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$DOC\\n\",\"content\":\"no frontmatter\\n\"}}"
expect_block "a path with a trailing newline is still denied"
raw "{
  \"tool_input\" : { \"content\" : \"no frontmatter\\n\", \"file_path\" : \"$DOC\" },
  \"cwd\" : \"$REPO\"
}"
expect_block "a pretty-printed payload with the path last is still denied"
printf -- '---\ntitle: Pre\nupdated: 2026-01-01\n---\nbody\n' > "$DOC"
raw "{\"cwd\":\"$REPO\",\"tool_name\":\"MultiEdit\",\"tool_input\":{\"file_path\":\"$DOC\",\"edits\":[{\"old_string\":\"body\",\"new_string\":\"text\"},{\"old_string\":\"title: Pre\\n\",\"new_string\":\"\"}]}}"
expect_block "a MultiEdit that drops the title is still denied"
rm -f "$DOC"
# What the full check has always let pass stays quiet: the filter follows the
# check, it does not widen it.
raw "{\"cwd\":\"$REPO\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$REPO/src/a.ts\",\"content\":\"// see .ai/features/x/pre-filter.md\"}}"
expect_quiet "a doc path that appears only in the content passes"
raw "{\"cwd\":\"$REPO\",\"tool_name\":\"NotebookEdit\",\"tool_input\":{\"notebook_path\":\"$DOC\",\"new_source\":\"no frontmatter\"}}"
expect_quiet "a NotebookEdit carries no file_path and passes"
raw "{\"cwd\":\"$REPO\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$REPO/.ai/features/x/UPPER.MD\",\"content\":\"no frontmatter\\n\"}}"
expect_quiet "an upper-case .MD is outside the scope, as it was before the filter"

# The filter matches bytes, not characters of the hook's locale (PR #449
# review): [[ =~ ]] decodes the payload in the locale first, and where the
# bytes before the path are not valid there the match failed and a write the
# full check denies was skipped. A raw invalid byte in a UTF-8 locale, and a
# valid UTF-8 payload from a project in a non-ASCII directory under a locale
# with another encoding. The second needs the locale installed.
raw_in() {  # raw_in <locale> <payload file> -> OUT, RC
  OUT=$(LC_ALL="$1" bash "$HOOK" < "$2" 2>/dev/null); RC=$?
}
# Read once and matched with case: under pipefail `locale -a | grep -q` fails
# when grep leaves early and locale dies of SIGPIPE.
LOCALES=$(locale -a 2>/dev/null || true)
UTF8_LOCALE=$(printf '%s\n' "$LOCALES" | grep -iE '^(C|en_US)\.utf-?8$' | head -1)
printf '{"note":"caf\351","cwd":"%s","tool_name":"Write","tool_input":{"file_path":"%s","content":"no frontmatter\\n"}}' "$REPO" "$DOC" > "$ROOT/invalid-byte.json"
raw_in "${UTF8_LOCALE:-en_US.UTF-8}" "$ROOT/invalid-byte.json"
expect_block "a payload with a raw invalid byte before the path is still denied"
NREPO="$ROOT/プロジェクト"
mkdir -p "$NREPO/.ai/features/x"
git init -q -b main "$NREPO"
printf '{"aiDir":".ai"}\n' > "$NREPO/.myspec.json"
printf '{"cwd":"%s","tool_name":"Write","tool_input":{"file_path":"%s/.ai/features/x/spec.md","content":"no frontmatter\\n"}}' "$NREPO" "$NREPO" > "$ROOT/non-ascii-dir.json"
raw_in "${UTF8_LOCALE:-en_US.UTF-8}" "$ROOT/non-ascii-dir.json"
expect_block "a doc in a non-ASCII directory is denied in a UTF-8 locale"
for loc in ja_JP.SJIS zh_TW.Big5; do
  case $'\n'"$LOCALES"$'\n' in *$'\n'"$loc"$'\n'*) HAVE=1 ;; *) HAVE=0 ;; esac
  if [ "$HAVE" = 1 ]; then
    raw_in "$loc" "$ROOT/non-ascii-dir.json"
    expect_block "a doc in a non-ASCII directory is still denied under LC_ALL=$loc"
  else
    echo "SKIP  locale $loc is not installed"
  fi
done

# --- a check that could not run: the outcome is what it was ---------------------
# frontmatter_issues returns 2 when a command failed (lib/content-checks.sh).
# Under set -e that status must not end the hook: with the temporal grep
# failing a valid new doc is denied for the field, as before the function had
# a status.
# shellcheck source=lib/tests/failing-tool.sh
. "$CLAUDE_PLUGIN_ROOT/lib/tests/failing-tool.sh"
failing_tool "$ROOT/grepfail" grep '^(updated'
OUT=$(jq -nc --arg c "$REPO" --arg f "$REPO/.ai/features/x/failed-grep.md" '{cwd: $c, tool_name: "Write", tool_input: {file_path: $f, content: "---\ntitle: T\nupdated: 2026-01-01\n---\nbody\n"}}' | PATH="$ROOT/grepfail:$PATH" bash "$HOOK" 2>/dev/null); RC=$?
expect_block "a failed temporal grep denies, exit 0"
reason | grep -q 'missing temporal field' && ok || fail "the deny names the field the failed grep did not find"
# The pre-check: an Edit to an existing doc is judged only when it changes the
# frontmatter region. With the region awk failing on both sides, both regions
# read empty and equal; a region that could not be read must not let the edit
# through unjudged.
failing_tool "$ROOT/regionfail" awk 'NR == 1 { if ('
DOC="$REPO/.ai/features/x/region.md"
mkdir -p "$(dirname "$DOC")"
printf -- '---\ntitle: T\nupdated: 2026-01-01\n---\nbody\n' > "$DOC"
OUT=$(jq -nc --arg c "$REPO" --arg f "$DOC" '{cwd: $c, tool_name: "Edit", tool_input: {file_path: $f, old_string: "updated: 2026-01-01\n", new_string: ""}}' | PATH="$ROOT/regionfail:$PATH" bash "$HOOK" 2>/dev/null); RC=$?
expect_block "an edit dropping the temporal field is judged when the region awk fails"
reason | grep -q 'missing temporal field' && ok || fail "the deny names the dropped field"
rm -f "$DOC"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
