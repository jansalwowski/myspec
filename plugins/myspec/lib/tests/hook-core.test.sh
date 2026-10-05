#!/usr/bin/env bash
# Fixture for lib/hook-core.sh, the primitives the hooks and the worktree
# libs share: payload parsing, physical paths, checkout facts, the state TTL
# and the settings reader. The session-state file has its own fixture,
# session-event.test.sh.
#
# Until hook-core existed, six scripts resolved "the main checkout" on their
# own and disagreed on two layouts. Each case below that settles one names the
# answer that wins:
#   --separate-git-dir, from its own checkout: five resolvers required the
#     common dir to be named `.git` and so found no main checkout (the edit
#     and branch guards then treated the checkout as a linked worktree and
#     let everything through); verify-before-stop's `git worktree list` named
#     the git dir, which is not a working tree. The toplevel wins: git dir and
#     common dir are the same, so this is the repository's main checkout.
#   a linked worktree of a bare repository: task-worktree.sh took the bare
#     dir's parent as the main checkout. None wins: a bare repository has no
#     working tree, and `git worktree list` marks its first entry `bare`.
#
# Usage: hook-core.test.sh [path-to-hook-core.sh]

set -uo pipefail

CORE="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../hook-core.sh}"
if [ ! -f "$CORE" ]; then
  echo "FATAL: hook-core.sh not found: $CORE" >&2
  exit 1
fi
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is required" >&2; exit 1; }
# shellcheck source=lib/hook-core.sh
. "$CORE"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }
eq() {  # eq <got> <want> <name>
  [ "$1" = "$2" ] && ok || fail "$3 (got '$1', want '$2')"
}

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/hook-core.XXXXXX")
ROOT=$(cd "$ROOT" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git_() { git -c init.defaultBranch=main -c protocol.file.allow=always "$@"; }
new_repo() { git_ init -q "$1" && git_ -C "$1" commit -q --allow-empty -m init; }

# --- payload_parse -------------------------------------------------------------

SUBAGENT_EXPR='[.agent_id, .agent_type] | map(strings | select(. != "")) | first'

# shellcheck disable=SC2016 # a literal $HOME: the payload must not expand it
P='{"cwd":"/c","session_id":"s1","agent_id":"","agent_type":"Explore","stop_hook_active":true,
    "tool_name":"Bash","tool_input":{"command":"echo '"'"'a b'"'"'\nls $HOME","file_path":"x.ts","edits":[1]}}'
payload_parse "$P" CWD=.cwd SID=.session_id SUB="$SUBAGENT_EXPR" ACTIVE=.stop_hook_active \
  TOOL=.tool_name CMD=.tool_input.command EDITS=.tool_input.edits CWDS="$HOOK_CWDS"
eq "$CWD" /c "payload: a string field"
eq "$SID" s1 "payload: session_id"
eq "$SUB" Explore "payload: an empty agent_id falls through to agent_type"
eq "$ACTIVE" true "payload: a boolean reads as true/false"
eq "$TOOL" Bash "payload: tool_name"
# shellcheck disable=SC2016 # literal $HOME, as above
eq "$CMD" "echo 'a b'"$'\n''ls $HOME' "payload: quotes, newlines and \$ survive unexpanded"
eq "$EDITS" '[1]' "payload: a non-string value is compact JSON"
eq "$CWDS" /c "payload: cwd candidates"

payload_parse '{"session_id":"s2"}' SID=.session_id CWD=.cwd SUB="$SUBAGENT_EXPR" ACTIVE='.stop_hook_active // false' CMD=.tool_input.command
eq "$SID|$CWD|$SUB|$ACTIVE|$CMD" "s2|||false|" "payload: missing fields are empty, a // default applies"

payload_parse '{"tool_input":"a string"}' CMD=.tool_input.command SID=.session_id
eq "$CMD|$SID" "|" "payload: a failing expression is empty and does not empty the others"

SID=stale
payload_parse 'not json {' SID=.session_id
eq "$SID" "" "payload: unparseable input leaves every name empty"

payload_parse '{"cwd":"","tool_input":{"cwd":"/a","workdir":"/b"}}' CWDS="$HOOK_CWDS"
eq "$CWDS" $'/a\n/b' "payload: an empty cwd is skipped; the tool's cwd and workdir follow"

payload_parse '{"workdir":"/w","workspace":{"cwd":"/w"},"session":{"cwd":"/w"}}' CWDS="$HOOK_CWDS"
eq "$CWDS" "" "payload: the guessed fields (.workdir, .workspace.cwd, .session.cwd) are not read"

rc=0; payload_parse '{}' 'bad-name=.x' 2>/dev/null || rc=$?
eq "$rc" 2 "payload: a name that is not a shell identifier is refused"

payload_parse '{"a":"x\n\ny\n\n"}' A=.a
eq "$A" $'x\n\ny' "payload: trailing newlines are dropped, inner ones kept"

# --- first_dir / existing_dir / physical_path ----------------------------------

mkdir -p "$ROOT/real dir/sub" "$ROOT/other"
ln -s "$ROOT/real dir" "$ROOT/link"
printf 'x\n' > "$ROOT/other/target.ts"
ln -s "$ROOT/other/target.ts" "$ROOT/real dir/file-link.ts"

eq "$(first_dir $'/nonexistent\n'"$ROOT/other")" "$ROOT/other" "first_dir skips a missing candidate"
rc=0; first_dir $'/nonexistent\n' >/dev/null || rc=$?
eq "$rc" 1 "first_dir fails when none exists"
eq "$(existing_dir "$ROOT/link/a/b/c.ts")" "$ROOT/link" "existing_dir walks up to an existing directory"

eq "$(physical_path "$ROOT/link/sub/a.ts")" "$ROOT/real dir/sub/a.ts" "physical_path resolves a symlinked directory (with a space)"
eq "$(physical_path "sub/a.ts" "$ROOT/link")" "$ROOT/real dir/sub/a.ts" "physical_path takes a relative path from the base"
eq "$(physical_path "../other/a.ts" "$ROOT/link/sub")" "$ROOT/real dir/other/a.ts" "physical_path: .. applies to the path as spelled, then resolves"
eq "$(physical_path "$ROOT/link/new/deeper/a.ts")" "$ROOT/real dir/new/deeper/a.ts" "physical_path appends a missing remainder to the resolved ancestor"
eq "$(physical_path "$ROOT/link/file-link.ts")" "$ROOT/real dir/file-link.ts" "physical_path keeps a symlinked last component as named"
eq "$(cd "$ROOT/link" && physical_path x.ts)" "$ROOT/real dir/x.ts" "physical_path defaults the base to \$PWD"

# --- checkout_facts --------------------------------------------------------------

facts() {  # facts <path> -> "root|linked|submodule|main", paths relative to ROOT
  if checkout_facts "$1"; then
    printf '%s|%s|%s|%s' "${CF_ROOT#"$ROOT"/}" "$CF_LINKED" "$CF_SUBMODULE" "${CF_MAIN#"$ROOT"/}"
  else
    printf 'none'
  fi
}

new_repo "$ROOT/plain"
mkdir -p "$ROOT/plain/src/deep"
eq "$(facts "$ROOT/plain")" "plain|0|0|plain" "plain repo: its own main checkout"
eq "$(facts "$ROOT/plain/src/deep")" "plain|0|0|plain" "plain repo: from a subdirectory"
eq "$(facts "$ROOT/plain/src/missing/x.ts")" "plain|0|0|plain" "plain repo: from a path that does not exist yet"
checkout_facts "$ROOT/plain"
eq "$CF_COMMON_DIR" "$ROOT/plain/.git" "plain repo: common dir is absolute"

git_ -C "$ROOT/plain" worktree add -q "$ROOT/plain/.claude/worktrees/wt" 2>/dev/null
eq "$(facts "$ROOT/plain/.claude/worktrees/wt")" "plain/.claude/worktrees/wt|1|0|plain" "linked worktree inside the main checkout: linked, main is the parent of .git"
checkout_facts "$ROOT/plain/.claude/worktrees/wt"
eq "$CF_GIT_DIR" "$ROOT/plain/.git/worktrees/wt" "linked worktree: git dir under worktrees/"

git_ -C "$ROOT/plain" worktree add -q --detach "$ROOT/sibling wt" 2>/dev/null
eq "$(facts "$ROOT/sibling wt")" "sibling wt|1|0|plain" "linked worktree outside, path with a space"

ln -s "$ROOT/plain" "$ROOT/plain-link"
ln -s "$ROOT/sibling wt" "$ROOT/wt-link"
eq "$(facts "$ROOT/plain-link/src")" "plain|0|0|plain" "symlinked root: facts are physical"
eq "$(facts "$ROOT/wt-link")" "sibling wt|1|0|plain" "symlinked linked worktree: facts are physical"

# A submodule, in the main checkout and inside a linked worktree.
new_repo "$ROOT/subsrc"
git_ -C "$ROOT/plain" submodule add -q "$ROOT/subsrc" mods/sub >/dev/null 2>&1
git_ -C "$ROOT/plain" commit -qm sub
eq "$(facts "$ROOT/plain/mods/sub")" "plain/mods/sub|0|1|plain/mods/sub" "submodule in the main checkout: not linked, its own main checkout"
checkout_facts "$ROOT/plain/mods/sub"
eq "$CF_SUPER" "$ROOT/plain" "submodule: CF_SUPER is the superproject"
git_ -C "$ROOT/plain" worktree add -q "$ROOT/wt-with-sub" 2>/dev/null
git_ -C "$ROOT/wt-with-sub" submodule update -q --init >/dev/null 2>&1
eq "$(facts "$ROOT/wt-with-sub/mods/sub")" "wt-with-sub/mods/sub|0|1|wt-with-sub/mods/sub" "submodule inside a linked worktree: a submodule, not itself linked"
checkout_facts "$ROOT/wt-with-sub/mods/sub"
eq "$CF_SUPER" "$ROOT/wt-with-sub" "submodule inside a linked worktree: CF_SUPER is the linked worktree"
checkout_facts "$CF_SUPER"
eq "$CF_LINKED|${CF_MAIN#"$ROOT"/}" "1|plain" "submodule inside a linked worktree: its superproject is linked, main is the main checkout"

# --separate-git-dir: the toplevel wins over `git worktree list` (the git dir)
# and over the .git-name rule (none).
git_ init -q --separate-git-dir="$ROOT/sep.git" "$ROOT/sep"
git_ -C "$ROOT/sep" commit -q --allow-empty -m init
eq "$(facts "$ROOT/sep")" "sep|0|0|sep" "separate-git-dir: the checkout is its own main checkout"
git_ -C "$ROOT/sep" worktree add -q "$ROOT/sep-wt" 2>/dev/null
eq "$(facts "$ROOT/sep-wt")" "sep-wt|1|0|" "separate-git-dir, linked worktree: linked, main unknown (git records no path to it)"

# A bare repository with worktrees: no main checkout.
git_ clone -q --bare "$ROOT/subsrc" "$ROOT/bare.git" 2>/dev/null
git_ -C "$ROOT/bare.git" worktree add -q "$ROOT/bare-wt" 2>/dev/null
eq "$(facts "$ROOT/bare-wt")" "bare-wt|1|0|" "bare repo worktree: linked, no main checkout"
eq "$(facts "$ROOT/bare.git")" "none" "bare git dir: not a work tree"

# The bare-in-.git layout (git clone --bare <url> project/.git): the common
# dir is named .git, but it is bare, so its parent is not a checkout.
mkdir -p "$ROOT/proj"
git_ clone -q --bare "$ROOT/subsrc" "$ROOT/proj/.git" 2>/dev/null
git_ -C "$ROOT/proj/.git" worktree add -q "$ROOT/proj/wt" 2>/dev/null
eq "$(facts "$ROOT/proj/wt")" "proj/wt|1|0|" "bare repo cloned into .git: no main checkout"

mkdir -p "$ROOT/nogit/a"
eq "$(facts "$ROOT/nogit/a")" "none" "no repository: fails"
checkout_facts "$ROOT/sibling wt"
checkout_facts "$ROOT/nogit/a"
eq "$CF_ROOT|$CF_MAIN|$CF_LINKED" "||0" "a failed call clears the facts"

# Cache: a second call for the same place is answered without git.
checkout_facts "$ROOT/plain/src"
# shellcheck disable=SC2317 # the stub runs only if the cache misses
eq "$(git() { return 1; }; checkout_facts "$ROOT/plain/src" && printf '%s' "${CF_ROOT#"$ROOT"/}")" "plain" "a repeated call is answered from the cache"

# The superproject lookup runs `git ls-files` in the parent repository: asked
# only where a submodule can be, not of a plain checkout or its worktrees.
TRACE="$ROOT/git-trace.log"
for d in "$ROOT/plain/src" "$ROOT/plain/.claude/worktrees/wt"; do
  rm -f "$TRACE"
  (CF_KEY=""; GIT_TRACE="$TRACE" checkout_facts "$d")
  ! grep -q 'run_command:' "$TRACE" 2>/dev/null && ok || fail "checkout_facts runs no child git for ${d#"$ROOT"/} ($(grep -c 'run_command:' "$TRACE") run)"
done
eq "$(CF_KEY=""; facts "$ROOT/plain/mods/sub")" "plain/mods/sub|0|1|plain/mods/sub" "a submodule is still found with the lookup made lazy"

# git < 2.31 does not know --path-format: rev-parse echoes the flag as its
# first line, rc 0, and prints the git dirs relative to the directory asked.
# Every hook then failed open. The wrapper strips the flag and echoes it.
old_git() {
  local a echo=""
  local -a args=()
  for a in "$@"; do
    case "$a" in --path-format=*) echo="$a" ;; *) args+=("$a") ;; esac
  done
  [ -z "$echo" ] || printf '%s\n' "$echo"
  command git "${args[@]}"
}
old_facts() {  # old_facts <path> [git-dirs] -> facts, or the dirs, under old_git
  # shellcheck disable=SC2317 # called through checkout_facts
  git() { old_git "$@"; }
  CF_KEY=""
  if [ -n "${2:-}" ]; then
    checkout_facts "$1"
    printf '%s' "$CF_GIT_DIR|$CF_COMMON_DIR"
  else
    facts "$1"
  fi
}
eq "$(old_facts "$ROOT/plain/src/deep")" "plain|0|0|plain" "git < 2.31: plain repo from a subdirectory"
eq "$(old_facts "$ROOT/plain/src/deep" dirs)" "$ROOT/plain/.git|$ROOT/plain/.git" "git < 2.31: the git dirs are absolute"
eq "$(old_facts "$ROOT/plain/.claude/worktrees/wt")" "plain/.claude/worktrees/wt|1|0|plain" "git < 2.31: linked worktree, main checkout found"
eq "$(old_facts "$ROOT/plain/mods/sub")" "plain/mods/sub|0|1|plain/mods/sub" "git < 2.31: submodule"

# --- TTL ----------------------------------------------------------------------------

eq "$HOOK_DECISION_TTL" "28800" "TTL constant (the isolation and implement lookups: session-event.test.sh)"

# --- ai_dir, read_setting, pretool_deny -------------------------------------------

eq "$(ai_dir "$ROOT/nogit")" ".ai" "ai_dir: no .myspec.json is the default"
printf '{"aiDir": "./docs/ai//"}\n' > "$ROOT/nogit/.myspec.json"
eq "$(ai_dir "$ROOT/nogit")" "docs/ai" "ai_dir: a leading ./ and trailing slashes are dropped"
printf '{"aiDir": ""}\n' > "$ROOT/nogit/.myspec.json"
eq "$(ai_dir "$ROOT/nogit")" ".ai" "ai_dir: an empty value is the default"

printf '{"hooks": {"markCodeChanged": {"extraCodeExtensions": ["svelte"], "bogus": 1}}}\n' > "$ROOT/plain/.myspec.json"
if read_setting hooks.markCodeChanged "$ROOT/plain"; then
  eq "$(printf '%s' "$SETTING" | jq -c '.extraCodeExtensions')" '["svelte"]' "read_setting returns the value as JSON"
else
  fail "read_setting reads a valid key"
fi
rc=0; read_setting '.bad' "$ROOT/plain" 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] && ok || fail "read_setting fails when the reader does"

# shellcheck disable=SC2317 # reached only if pretool_deny fails to exit
out=$(pretool_deny 'no "way"'; echo unreachable)
eq "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision + "|" + .hookSpecificOutput.permissionDecisionReason')" 'deny|no "way"' "pretool_deny prints the deny form and exits"
eq "$(printf '%s' "$out" | jq -r 'has("decision") or has("reason")')" false "pretool_deny prints no legacy decision/reason pair (the 3.0 host floor reads hookSpecificOutput)"

# shellcheck disable=SC2317 # reached only if decision_block fails to exit
out=$(decision_block 'Fix %s:\n\n%s\n' "a.ts" 'line "1"'; echo unreachable)
eq "$(printf '%s' "$out" | jq -r '.decision')" block "decision_block prints the block form and exits"
eq "$(printf '%s' "$out" | jq -r '.reason')" $'Fix a.ts:\n\nline "1"' "decision_block formats the reason with printf"
eq "$(printf '%s' "$out" | jq -j '.reason' | tail -c 1 | od -An -c | tr -d ' ')" '\n' "decision_block keeps a trailing newline"

# --- path-normalize.sh sources hook-core.sh, and survives without it -----------
# Project scripts source path-normalize.sh (rules/paths.md). A lazy source of
# a missing hook-core.sh inside canonical_main_worktree aborted a set -e
# caller; the path itself is the fallback.
PN="$(dirname "$CORE")/path-normalize.sh"
mkdir -p "$ROOT/pn-alone"
cp "$PN" "$ROOT/pn-alone/path-normalize.sh"
eq "$(bash -e -c '. "$1"; canonical_main_worktree "$2"; echo AFTER' _ "$ROOT/pn-alone/path-normalize.sh" "$ROOT/plain/.claude/worktrees/wt" 2>&1)" \
  "$ROOT/plain/.claude/worktrees/wt"$'\n'"AFTER" "path-normalize without hook-core: the path itself, and the caller goes on"
eq "$(bash -e -c '. "$1"; canonical_main_worktree "$2"' _ "$PN" "$ROOT/plain/.claude/worktrees/wt" 2>&1)" \
  "$ROOT/plain" "path-normalize with hook-core: a linked worktree maps to its main checkout"

# --- file_sha256 ----------------------------------------------------------------------

printf 'abc' > "$ROOT/hash.txt"
eq "$(file_sha256 "$ROOT/hash.txt")" "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" "file_sha256: the SHA-256 of the file's bytes"
rc=0; file_sha256 "$ROOT/no-such-file" >/dev/null || rc=$?
[ "$rc" -ne 0 ] && ok || fail "file_sha256 fails on a missing file"
rc=0; file_sha256 "$ROOT" >/dev/null || rc=$?
[ "$rc" -ne 0 ] && ok || fail "file_sha256 fails on a directory"

# --- lock_paths_for --------------------------------------------------------------------

mkdir -p "$ROOT/locks/a" "$ROOT/locks/b" "$ROOT/locks/c/d" "$ROOT/locks/sp ace"
for f in a/x.lock b/x.lock c/d/x.lock "sp ace/x.lock" top.lock; do printf 'l' > "$ROOT/locks/$f"; done
mkdir -p "$ROOT/locks/dir.lock"
eq "$(lock_paths_for "$ROOT/locks" '*/x.lock' | paste -sd, -)" "a/x.lock,b/x.lock,sp ace/x.lock" "lock_paths_for: a * stays within one directory"
eq "$(lock_paths_for "$ROOT/locks" '[ab]/x.lock' | paste -sd, -)" "a/x.lock,b/x.lock" "lock_paths_for: [...] is a class"
eq "$(lock_paths_for "$ROOT/locks" 'sp ace/x.lock' top.lock nope.lock | paste -sd, -)" "sp ace/x.lock,top.lock" "lock_paths_for: a space is not a separator, a missing file prints nothing"
eq "$(lock_paths_for "$ROOT/locks" '*.lock' | paste -sd, -)" "top.lock" "lock_paths_for: only regular files"

# --- glob-regex comes along -------------------------------------------------------

declare -F glob_regex >/dev/null && ok || fail "sourcing hook-core makes glob_regex available"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
