#!/usr/bin/env bash
# End-to-end fixture for the Stop gate's content checks (R14, #263): the
# catch-all for writes the PreToolUse content gates never see. A Bash
# heredoc, `sed -i` or `tee` is recorded by mark-code-changed.sh as a write,
# and at Stop lib/stop-gate/content.sh runs the three checks over the lines
# such a write added (before/after snapshots taken at PreToolUse and
# PostToolUse): absolute homedir paths (in the files paths.md covers),
# frontmatter (a ${aiDir} doc the session created, or whose frontmatter it
# changed) and the reuse audit (a tech-spec the session created). What it
# must leave alone: a line the file held before the session (in HEAD or
# not), a line another session added (in another file or the same one), a
# tech-spec that predates the session, a gitignored file, and Edit-tool
# writes. What it must still catch: a Bash write committed in the session.
# The net effect counts, not the union of the writes (#343): a line changed
# and restored, moved, or reverted around another session's write is not
# added; a partial revert, a second copy of an existing line, and the last of
# several changes are; a file moved away and back was not created.
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

# mark <sid-suffix> <event> <command>: the harness's call of
# mark-code-changed.sh for a Bash command at <event>.
mark() {
  jq -nc --arg s "$SID-$1" --arg e "$2" --arg c "$REPO" --arg cmd "$3" '{hook_event_name: $e, session_id: $s, tool_name: "Bash", cwd: $c, tool_input: {command: $cmd}}' \
    | bash "$MARK" >/dev/null 2>&1
}

# bashcmd <sid-suffix> <command>: runs the command in the repo the way the
# harness does: PreToolUse Bash (the snapshot), the command, PostToolUse Bash.
bashcmd() {
  mark "$1" PreToolUse "$2"
  (cd "$REPO" && eval "$2") >/dev/null 2>&1
  mark "$1" PostToolUse "$2"
}

# editcall <sid-suffix> <rel>: records an Edit of <rel> (PostToolUse), as the
# harness does after the PreToolUse hooks allowed it.
editcall() {
  jq -nc --arg s "$SID-$1" --arg c "$REPO" --arg f "$REPO/$2" '{hook_event_name: "PostToolUse", session_id: $s, tool_name: "Edit", cwd: $c, tool_input: {file_path: $f, old_string: "a", new_string: "b"}}' \
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

# A tech-spec another session created and committed predates this one, so
# an edit elsewhere in it is not judged for the section.
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

# --- the baseline is the session's own Bash writes, not HEAD (PR #274 review) -------
# Uncommitted files with defects that predate the session, edited through the
# Edit tool (which its PreToolUse hooks judged): nothing to judge at Stop.
printf -- '---\ntitle: U\ncreated: 2026-01-01\n---\n\nbody a\n' > "$REPO/.ai/features/old/tech-spec.md"
printf 'old leak %s\nline a\n' "$LEAK" > "$REPO/docs/uncommitted.md"
editcall 16 .ai/features/old/tech-spec.md
editcall 16 docs/uncommitted.md
OUT=$(stop 16)
[ "$(decision "$OUT")" = approve ] && ok || fail "Edit-tool writes to uncommitted files with old defects approve (got: ${OUT:0:300})"

# A Bash append beside an uncommitted leak that predates the session.
bashcmd 17 "printf 'clean\n' >> docs/uncommitted.md"
OUT=$(stop 17)
[ "$(decision "$OUT")" = approve ] && ok || fail "a clean Bash append to an uncommitted file with an old leak approves (got: ${OUT:0:300})"
rm -f "$REPO/docs/uncommitted.md"
git -C "$REPO" checkout -q -- .

# A Bash write committed in the same session is still this session's.
bashcmd 18 "printf 'see $LEAK\n' >> docs/committed.md && git add -A && git commit -qm leak"
OUT=$(stop 18)
[ "$(decision "$OUT")" = block ] && ok || fail "a Bash leak committed in the session still blocks (got: ${OUT:0:200})"
expect_in "lines this session added to docs/committed.md" "$(reason "$OUT")" "the committed file is named"

# Two sessions append to one shared file: each is judged on its own lines.
bashcmd 19 "printf 'x leak $LEAK\n' >> docs/shared.md"
bashcmd 20 "printf 'y clean\n' >> docs/shared.md"
OUT=$(stop 20)
[ "$(decision "$OUT")" = approve ] && ok || fail "another session's line in a shared file is not this session's (got: ${OUT:0:300})"
OUT=$(stop 19)
[ "$(decision "$OUT")" = block ] && ok || fail "the session that added the leak to the shared file is blocked (got: ${OUT:0:200})"
expect_in "line 1: /Users/alice" "$(reason "$OUT")" "the shared file's leak line is named"
rm -f "$REPO/docs/shared.md"

# A leak a Bash write added and a later write removed is gone.
bashcmd 21 "printf 'see $LEAK\n' > docs/fixed.md"
bashcmd 21 "printf 'fixed\n' > docs/fixed.md"
OUT=$(stop 21)
[ "$(decision "$OUT")" = approve ] && ok || fail "a leak removed by a later Bash write approves (got: ${OUT:0:300})"
rm -f "$REPO/docs/fixed.md"

# --- the net effect of the session's writes, not their union (#343) ---------------
# sedi <expr> <rel>: a portable `sed -i` command line for bashcmd.
sedi() { printf "sed -i.bak '%s' %s && rm -f %s.bak" "$1" "$2" "$2"; }

# The report: a line one Bash write changed and a later one restored was
# judged as added, on every Stop, committed or not.
bashcmd 60 "$(sedi 's#^old leak: .*#old leak: renamed#' docs/notes.md)"
bashcmd 60 "$(sedi "s#^old leak: renamed\$#old leak: $LEAK#" docs/notes.md)"
git -C "$REPO" diff --quiet -- docs/notes.md && ok || fail "fixture: the revert restored docs/notes.md byte for byte"
OUT=$(stop 60)
[ "$(decision "$OUT")" = approve ] && ok || fail "a line changed and restored by two Bash writes approves (#343; got: ${OUT:0:300})"
bashcmd 60 "git add -A && git commit -qm noop --allow-empty"
OUT=$(stop 60)
[ "$(decision "$OUT")" = approve ] && ok || fail "the restored line still approves after a commit (#343; got: ${OUT:0:300})"
git -C "$REPO" reset -q --hard HEAD~1

# A partial revert: of two changed lines one is restored, the other still
# leaks.
bashcmd 61 "$(sedi "s#^clean line\$#clean line $LEAK#; s#^old leak: .*#old leak: gone#" docs/notes.md)"
bashcmd 61 "$(sedi "s#^old leak: gone\$#old leak: $LEAK#" docs/notes.md)"
OUT=$(stop 61)
[ "$(decision "$OUT")" = block ] && ok || fail "a partial revert still blocks on the line left changed (got: ${OUT:0:200})"
R=$(reason "$OUT")
expect_in "line 6: /Users/alice" "$R" "the line left changed is named"
expect_not_in "line 5:" "$R" "the restored line is not named"
git -C "$REPO" checkout -q -- docs/notes.md

# Change, then change again: only the last text counts.
bashcmd 62 "$(sedi 's#^clean line$#clean line, once#' docs/notes.md)"
bashcmd 62 "$(sedi "s#^clean line, once\$#clean line, twice $LEAK#" docs/notes.md)"
OUT=$(stop 62)
[ "$(decision "$OUT")" = block ] && ok || fail "a line changed twice, the second time to a leak, blocks (got: ${OUT:0:200})"
expect_in "line 6: /Users/alice" "$(reason "$OUT")" "the last text is named"
git -C "$REPO" checkout -q -- docs/notes.md
bashcmd 63 "$(sedi "s#^clean line\$#clean line $LEAK#" docs/notes.md)"
bashcmd 63 "$(sedi "s#^clean line /.*#clean line, fixed#" docs/notes.md)"
OUT=$(stop 63)
[ "$(decision "$OUT")" = approve ] && ok || fail "a leak changed again to a clean text approves (got: ${OUT:0:300})"
git -C "$REPO" checkout -q -- docs/notes.md

# A second copy of a line the file already held is the session's; the
# original is not.
bashcmd 64 "printf 'old leak: $LEAK\n' >> docs/notes.md"
OUT=$(stop 64)
[ "$(decision "$OUT")" = block ] && ok || fail "a second copy of an old leak line blocks (got: ${OUT:0:200})"
R=$(reason "$OUT")
expect_in "line 7: /Users/alice" "$R" "the copy's line is named"
expect_not_in "line 5:" "$R" "the original line is not named"
git -C "$REPO" checkout -q -- docs/notes.md

# A leak deleted in one section and pasted into another by one rewrite is
# judged at its new line (PR #347 review). A line moved within the file looks
# the same, so it is judged too: no rule tells the two apart.
bashcmd 65 "cat > docs/notes.md <<'EOF'
---
title: Notes
updated: 2026-01-01
---
clean line
## B
old leak: $LEAK
EOF"
OUT=$(stop 65)
[ "$(decision "$OUT")" = block ] && ok || fail "a leak line deleted in one section and pasted into another blocks (PR #347 review; got: ${OUT:0:200})"
R=$(reason "$OUT")
expect_in "line 7: /Users/alice" "$R" "the pasted line is named"
expect_not_in "line 5:" "$R" "no other line is named"
git -C "$REPO" checkout -q -- docs/notes.md
bashcmd 74 "awk 'NR == 5 { l = \$0; next } { print } END { print l }' docs/notes.md > docs/notes.tmp && mv docs/notes.tmp docs/notes.md"
[ "$(tail -n 1 "$REPO/docs/notes.md")" = "old leak: $LEAK" ] && ok || fail "fixture: the old leak line moved to the end"
OUT=$(stop 74)
[ "$(decision "$OUT")" = block ] && ok || fail "an old leak line moved within the file is judged like a paste (got: ${OUT:0:200})"
expect_in "line 6: /Users/alice" "$(reason "$OUT")" "the moved line is named where it is now"
git -C "$REPO" checkout -q -- docs/notes.md

# Another session writes between a change and its revert: its line stays its
# own, and the revert is still a revert. A net diff from this session's first
# snapshot to the file now would sweep the other session's line in.
bashcmd 66 "$(sedi 's#^old leak: .*#old leak: renamed#' docs/notes.md)"
bashcmd 67 "printf 'other $LEAK\n' >> docs/notes.md"
bashcmd 66 "$(sedi "s#^old leak: renamed\$#old leak: $LEAK#" docs/notes.md)"
OUT=$(stop 66)
[ "$(decision "$OUT")" = approve ] && ok || fail "a revert around another session's leak approves (got: ${OUT:0:300})"
OUT=$(stop 67)
[ "$(decision "$OUT")" = block ] && ok || fail "the other session's leak blocks that session (got: ${OUT:0:200})"
R=$(reason "$OUT")
expect_in "line 7: /Users/alice" "$R" "the other session's line is named"
expect_not_in "line 5:" "$R" "the reverted line is not the other session's either"
git -C "$REPO" checkout -q -- docs/notes.md

# An Edit call between two Bash writes: the second write takes its own
# snapshot at PreToolUse, after the Edit, and the revert still nets to
# nothing.
bashcmd 68 "$(sedi 's#^old leak: .*#old leak: renamed#' docs/notes.md)"
editcall 68 docs/notes.md
bashcmd 68 "$(sedi "s#^old leak: renamed\$#old leak: $LEAK#" docs/notes.md)"
OUT=$(stop 68)
[ "$(decision "$OUT")" = approve ] && ok || fail "a revert with an Edit call between approves (got: ${OUT:0:300})"
git -C "$REPO" checkout -q -- docs/notes.md

# A write with no `pre` event (only PostToolUse reached the hook: a session
# that started before the snapshots existed) falls back to HEAD as its
# before. The session's earlier copy of an old line, which an Edit call
# removed since, is not counted again against that baseline (PR #347 review).
bashcmd 75 "printf 'old leak: $LEAK\n' >> docs/notes.md"
sed -i.bak '$d' "$REPO/docs/notes.md" && rm -f "$REPO/docs/notes.md.bak"
editcall 75 docs/notes.md
(cd "$REPO" && printf 'clean tail\n' >> docs/notes.md)
mark 75 PostToolUse "printf 'clean tail\n' >> docs/notes.md"
jq -e -s '[.[] | select(.t == "pre")] | length == 1' "$REPO/.claude/state/sessions/$SID-75.jsonl" >/dev/null \
  && ok || fail "fixture: the last write has no pre event"
OUT=$(stop 75)
[ "$(decision "$OUT")" = approve ] && ok || fail "a write without a snapshot does not judge an old line against HEAD (PR #347 review; got: ${OUT:0:300})"
git -C "$REPO" checkout -q -- docs/notes.md

# A no-op on a missing file (a redirect into a directory that does not exist
# yet: the scanner names the target, which has no file before and none after)
# is no write to it. A tech-spec the Write tool then created, and a later Bash
# append, do not make it "created" by Bash (PR #347 review).
FAILW="printf 'x\\n' > .ai/features/w/tech-spec.md"
mark 76 PreToolUse "$FAILW"
(cd "$REPO" && eval "$FAILW") >/dev/null 2>&1
mark 76 PostToolUseFailure "$FAILW"
jq -e -s 'any(.[]; .t == "write" and .rel == ".ai/features/w/tech-spec.md" and .blob == "")' "$REPO/.claude/state/sessions/$SID-76.jsonl" >/dev/null \
  && ok || fail "fixture: the failed redirect is recorded as a write that left no file"
mkdir -p "$REPO/.ai/features/w"
printf -- '---\ntitle: W\ncreated: 2026-01-01\n---\n\n### Architecture\nwritten\n' > "$REPO/.ai/features/w/tech-spec.md"
editcall 76 .ai/features/w/tech-spec.md
bashcmd 76 "printf 'appended\n' >> .ai/features/w/tech-spec.md"
OUT=$(stop 76)
[ "$(decision "$OUT")" = approve ] && ok || fail "a failed redirect to a missing file does not make the file Bash-created (PR #347 review; got: ${OUT:0:300})"
rm -rf "$REPO/.ai/features/w"

# Frontmatter changed and restored: a doc whose frontmatter was already bad
# is not judged. One the session leaves changed is.
printf -- '---\ntitle: Bad\n---\nbody\n' > "$REPO/.ai/features/old/bad.md"
git -C "$REPO" add -A && git -C "$REPO" commit -qm bad
bashcmd 69 "$(sedi 's#^title: Bad$#title: Bad, renamed#' .ai/features/old/bad.md)"
bashcmd 69 "$(sedi 's#^title: Bad, renamed$#title: Bad#' .ai/features/old/bad.md)"
OUT=$(stop 69)
[ "$(decision "$OUT")" = approve ] && ok || fail "frontmatter changed and restored on a doc with old frontmatter issues approves (got: ${OUT:0:300})"
bashcmd 70 "$(sedi 's#^title: Bad$#title: Bad, renamed#' .ai/features/old/bad.md)"
bashcmd 70 "printf 'more body\n' >> .ai/features/old/bad.md"
OUT=$(stop 70)
[ "$(decision "$OUT")" = block ] && ok || fail "frontmatter left changed, then a body write, still blocks (got: ${OUT:0:200})"
expect_in "missing temporal field" "$(reason "$OUT")" "the frontmatter issue is named"
git -C "$REPO" reset -q --hard HEAD~1

# A file removed and restored (`mv` away and back) was not created: the
# pre-hook tech-spec is not held to the reuse audit, and its lines are not
# added.
bashcmd 71 "mv .ai/features/old/tech-spec.md .ai/features/old/moved.md"
bashcmd 71 "mv .ai/features/old/moved.md .ai/features/old/tech-spec.md"
bashcmd 71 "mv docs/notes.md docs/moved.md"
bashcmd 71 "mv docs/moved.md docs/notes.md"
git -C "$REPO" diff --quiet HEAD && ok || fail "fixture: the moves back restored the tree"
OUT=$(stop 71)
[ "$(decision "$OUT")" = approve ] && ok || fail "files moved away and back approve: not created, no lines added (got: ${OUT:0:300})"
git -C "$REPO" reset -q --hard HEAD

# A file the session created, removed and created again is still created.
bashcmd 72 "printf '# P\n' > .ai/features/old/p.md"
bashcmd 72 "rm .ai/features/old/p.md"
bashcmd 72 "printf '# P\nagain\n' > .ai/features/old/p.md"
OUT=$(stop 72)
[ "$(decision "$OUT")" = block ] && ok || fail "a doc created, removed and created again is still judged as created (got: ${OUT:0:200})"
expect_in "Frontmatter issue in .ai/features/old/p.md" "$(reason "$OUT")" "the recreated doc is named"
rm -f "$REPO/.ai/features/old/p.md"

# A CRLF file under 'text eol=crlf': the blobs are LF, the file CRLF, and a
# revert still nets to nothing.
printf '*.md text eol=crlf\n' > "$REPO/.gitattributes"
printf 'see %s\r\nclean\r\n' "$LEAK" > "$REPO/docs/crlf-rev.md"
git -C "$REPO" add -A && git -C "$REPO" commit -qm crlf
bashcmd 73 "$(sedi 's#^see .*#see nothing#' docs/crlf-rev.md)"
bashcmd 73 "$(sedi "s#^see nothing#see $LEAK#" docs/crlf-rev.md)"
OUT=$(stop 73)
[ "$(decision "$OUT")" = approve ] && ok || fail "a CRLF line changed and restored approves (got: ${OUT:0:300})"
git -C "$REPO" reset -q --hard HEAD~1

# --- redirect forms the command scanner must see (PR #274 review) -----------------
# A redirect after the heredoc marker, a pipe after it, a brace group's or
# subshell's redirect, and a redirect before the command name.
n=30
for cmd in \
  "cat <<'EOF' > docs/r.md
see $LEAK
EOF" \
  "cat <<EOF >>docs/r.md
see $LEAK
EOF" \
  "cat <<-EOF > docs/r.md
	see $LEAK
	EOF" \
  "cat << EOF > docs/r.md
see $LEAK
EOF" \
  "cat <<\\EOF > docs/r.md
see $LEAK
EOF" \
  "cat <<'EOF' | tee docs/r.md
see $LEAK
EOF" \
  "cat <<A <<B > docs/r.md
a
A
see $LEAK
B" \
  "{ printf 'see $LEAK\n'; } >> docs/r.md" \
  "( printf 'see $LEAK\n' ) > docs/r.md" \
  ">docs/r.md printf 'see $LEAK\n'"; do
  bashcmd "$n" "$cmd"
  OUT=$(stop "$n")
  [ "$(decision "$OUT")" = block ] && ok || fail "a leak written by '${cmd%%$'\n'*}' blocks (got: ${OUT:0:200})"
  rm -f "$REPO/docs/r.md"
  n=$((n + 1))
done

# An arithmetic shift is not a heredoc: the redirect after it still counts.
bashcmd 45 "echo \$(( 1 << 2 )) > docs/r.md && printf 'see $LEAK\n' >> docs/r.md"
OUT=$(stop 45)
[ "$(decision "$OUT")" = block ] && ok || fail "an arithmetic shift does not hide the redirects after it (got: ${OUT:0:200})"
rm -f "$REPO/docs/r.md"

# --- a CRLF line is judged when git normalises line endings (PR #274 review) ------
git -C "$REPO" config core.autocrlf input
bashcmd 46 "printf 'see $LEAK\r\n' >> docs/crlf.md"
OUT=$(stop 46)
[ "$(decision "$OUT")" = block ] && ok || fail "a CRLF leak blocks under core.autocrlf=input (got: ${OUT:0:200})"
rm -f "$REPO/docs/crlf.md"
git -C "$REPO" config --unset core.autocrlf
printf '*.md text eol=crlf\n' > "$REPO/.gitattributes"
bashcmd 47 "printf 'see $LEAK\r\n' >> docs/crlf.md"
OUT=$(stop 47)
[ "$(decision "$OUT")" = block ] && ok || fail "a CRLF leak blocks under 'text eol=crlf' (got: ${OUT:0:200})"
rm -f "$REPO/docs/crlf.md" "$REPO/.gitattributes"

# --- a write git cannot snapshot is still judged (PR #274 review) ------------------
# A read-only object store: hash-object -w fails. The write is still judged,
# not dropped. Root writes through the mode bits, so the case only means
# something as another user.
if [ "$(id -u)" != 0 ]; then
  chmod -R a-w "$REPO/.git/objects"
  bashcmd 48 "printf 'read-only store $LEAK\n' >> docs/ro.md"
  chmod -R u+w "$REPO/.git/objects"
  OUT=$(stop 48)
  [ "$(decision "$OUT")" = block ] && ok || fail "a write with no after-blob (read-only object store) still blocks (got: ${OUT:0:200})"
  rm -f "$REPO/docs/ro.md"
  # The snapshots are kept beside the session file instead, so the pair is
  # still this write's own: another writer's leak in the file is not this
  # session's, and a commit after the write hides nothing. The file's content
  # before the write comes from outside the hooks, so the store does not hold
  # it already.
  printf 'other %s\n' "$LEAK" >> "$REPO/docs/ro.md"
  chmod -R a-w "$REPO/.git/objects"
  bashcmd 57 "printf 'clean line\n' >> docs/ro.md"
  chmod -R u+w "$REPO/.git/objects"
  OUT=$(stop 57)
  [ "$(decision "$OUT")" = approve ] && ok || fail "under a read-only object store another writer's leak in the file does not block this session (got: ${OUT:0:300})"
  rm -f "$REPO/docs/ro.md"
  printf 'uncommitted line\n' >> "$REPO/docs/notes.md"
  chmod -R a-w "$REPO/.git/objects"
  bashcmd 58 "printf 'see $LEAK\n' >> docs/notes.md"
  chmod -R u+w "$REPO/.git/objects"
  git -C "$REPO" commit -qam leak
  OUT=$(stop 58)
  [ "$(decision "$OUT")" = block ] && ok || fail "a leak written under a read-only object store still blocks once committed (got: ${OUT:0:200})"
  expect_in "line 8: /Users/alice" "$(reason "$OUT")" "the committed leak's line is named"
  git -C "$REPO" reset -q --hard HEAD~1
  ls "$REPO/.claude/state/sessions/$SID-58.blobs/" >/dev/null 2>&1 && ok || fail "the copies are kept beside the session file"
  # No copy either (here: a file where the copies' directory would go): "@",
  # and the write is still judged on the file as it is at Stop.
  : > "$REPO/.claude/state/sessions/$SID-59.blobs"
  chmod -R a-w "$REPO/.git/objects"
  bashcmd 59 "printf 'nowhere to keep $LEAK\n' >> docs/ro.md"
  chmod -R u+w "$REPO/.git/objects"
  jq -e -s 'any(.[]; .t == "write" and .blob == "@")' "$REPO/.claude/state/sessions/$SID-59.jsonl" >/dev/null \
    && ok || fail "a write neither hashed nor kept records blob \"@\""
  OUT=$(stop 59)
  [ "$(decision "$OUT")" = block ] && ok || fail "a write neither hashed nor kept still blocks (got: ${OUT:0:200})"
  rm -f "$REPO/docs/ro.md"
  # The first pair cannot be read (its kept copy is gone): it still decides
  # "created", from its before, so a tech-spec moved away and back (and
  # appended to) is not judged as created (PR #347 review). An uncommitted
  # change from outside the hooks first, so the store does not hold it.
  printf 'outside %s\n' "$$" >> "$REPO/.ai/features/old/tech-spec.md"
  chmod -R a-w "$REPO/.git/objects"
  bashcmd 77 "mv .ai/features/old/tech-spec.md .ai/features/old/moved.md"
  bashcmd 77 "mv .ai/features/old/moved.md .ai/features/old/tech-spec.md && printf 'more\n' >> .ai/features/old/tech-spec.md"
  chmod -R u+w "$REPO/.git/objects"
  FIRST=$(jq -r -s '[.[] | select(.t == "pre" and .rel == ".ai/features/old/tech-spec.md")][0].blob' "$REPO/.claude/state/sessions/$SID-77.jsonl")
  case "$FIRST" in kept:*) ok ;; *) fail "fixture: the first snapshot is a kept copy (got: $FIRST)" ;; esac
  rm -f "$REPO/.claude/state/sessions/$SID-77.blobs/${FIRST#kept:}"
  OUT=$(stop 77)
  [ "$(decision "$OUT")" = approve ] && ok || fail "an unreadable first pair still decides that the file was not created (PR #347 review; got: ${OUT:0:300})"
  git -C "$REPO" checkout -q -- .ai/features/old/tech-spec.md
fi

# A file the checks never judge is not hashed: a binary adds no loose object.
objects() { git -C "$REPO" count-objects | cut -d' ' -f1; }
before_objects=$(objects)
bashcmd 49 "head -c 4096 /dev/zero > docs/blob.png && printf 'x\n' >> docs/blob.png"
[ "$(objects)" = "$before_objects" ] && ok || fail "a binary Bash write adds no loose object ($before_objects -> $(objects))"
OUT=$(stop 49)
[ "$(decision "$OUT")" = approve ] && ok || fail "a binary Bash write approves (got: ${OUT:0:200})"
rm -f "$REPO/docs/blob.png"

# A large text file the checks judge gets a real before/after pair whatever
# its size (PR #274 review): no fallback to HEAD, nor to the file as it is at
# Stop. A large file outside the checks' scope is not hashed.
big_lines() {  # big_lines <prefix>: 15000 lines, about 1.3 MB
  awk -v p="$1" 'BEGIN { for (i = 0; i < 15000; i++) print p " line " i " of a large generated file, padded out to about ninety bytes" }'
}
big_lines filler > "$REPO/docs/big.md"
git -C "$REPO" add docs/big.md
git -C "$REPO" commit -qm big
[ "$(wc -c < "$REPO/docs/big.md")" -gt 1048576 ] && ok || fail "fixture: docs/big.md is above 1 MiB"
# A leak committed in the session still blocks: its baseline is the blob taken
# before the write, not HEAD.
bashcmd 50 "printf 'see $LEAK\n' >> docs/big.md && git commit -qam leak"
OUT=$(stop 50)
[ "$(decision "$OUT")" = block ] && ok || fail "a leak in a doc above 1 MiB committed in the session still blocks (got: ${OUT:0:200})"
expect_in "line 15001: /Users/alice" "$(reason "$OUT")" "the large doc's leak line is named"
git -C "$REPO" reset -q --hard HEAD~1
# Another session's uncommitted leak in a shared large file is not this
# session's, written before or after this session's line.
bashcmd 52 "printf 'other $LEAK\n' >> docs/big.md"
bashcmd 53 "printf 'clean line\n' >> docs/big.md"
bashcmd 54 "printf 'later $LEAK\n' >> docs/big.md"
OUT=$(stop 53)
[ "$(decision "$OUT")" = approve ] && ok || fail "another session's leak in a shared doc above 1 MiB does not block this session (got: ${OUT:0:300})"
OUT=$(stop 52)
[ "$(decision "$OUT")" = block ] && ok || fail "the session that leaked into the shared large doc is blocked (got: ${OUT:0:200})"
git -C "$REPO" checkout -q -- docs/big.md
before_objects=$(objects)
bashcmd 55 "awk 'BEGIN { for (i = 0; i < 15000; i++) print \"RUN echo line \" i \" of a large generated file, padded out to about ninety bytes\" }' > Dockerfile"
[ "$(wc -c < "$REPO/Dockerfile")" -gt 1048576 ] && ok || fail "fixture: Dockerfile is above 1 MiB"
[ "$(objects)" = "$before_objects" ] && ok || fail "a large file outside the checks' scope adds no loose object ($before_objects -> $(objects))"
rm -f "$REPO/Dockerfile"

# --- a write in a command that exits non-zero (PR #274 review) ---------------------
# The harness sends a Bash call that exits non-zero to PostToolUseFailure, not
# PostToolUse, with the same tool_input; the hook must be registered there too.
HOOKS_JSON="$CLAUDE_PLUGIN_ROOT/hooks.json"
jq -e '.hooks.PostToolUseFailure[]? | select(.matcher == "Bash") | .hooks[] | select(.command | endswith("/hooks/mark-code-changed.sh"))' "$HOOKS_JSON" >/dev/null \
  && ok || fail "hooks.json registers mark-code-changed.sh for Bash at PostToolUseFailure"
FAILCMD="printf 'see $LEAK\n' > docs/failed.md && false"
mark 51 PreToolUse "$FAILCMD"
(cd "$REPO" && eval "$FAILCMD") >/dev/null 2>&1
mark 51 PostToolUseFailure "$FAILCMD"
OUT=$(stop 51)
[ "$(decision "$OUT")" = block ] && ok || fail "a leak written by a command that then fails blocks (got: ${OUT:0:200})"
rm -f "$REPO/docs/failed.md"

# --- the continuation after a block is approved (R10) -----------------------------
bashcmd 15 "printf 'see $LEAK\n' > docs/again.md"
OUT=$(jq -nc --arg s "$SID-15" --arg c "$REPO" '{session_id: $s, cwd: $c, stop_hook_active: true}' | bash "$HOOK" 2>/dev/null)
[ "$(decision "$OUT")" = approve ] && ok || fail "stop_hook_active approves without re-running the content checks"
rm -f "$REPO/docs/again.md"

# --- a project without verification.json still gets the content checks ------------
[ ! -f "$REPO/.claude/verification.json" ] && ok || fail "fixture: no verification.json"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
