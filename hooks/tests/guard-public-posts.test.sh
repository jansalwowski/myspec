#!/usr/bin/env bash
# Regression fixture for guard-public-posts.sh (#380).
#
# The hook stops a gh post from a private project P to a different, public
# repository when the post names P's identifiers: the origin owner and repo,
# branch names, commits, configured names, and the always-private shapes
# (session links, home paths). What it must leave alone: every Bash call that
# is not a gh post (before any process starts), a post to P's own origin, a
# post to a private target, a clean post (without asking gh at all), generic
# branch names, hex that names no commit in P, a gh verb inside quoted text,
# a GET through gh api, and a command carrying the override. When gh cannot
# tell the visibility the target counts as public; without gh nothing runs.
# A fork's upstream already has the branches and commits it shares with P.
# gh is a stub that answers `api repos/<o>/<r>` from $FX/vis/<o>_<r> and logs
# every call.
#
# Usage: guard-public-posts.test.sh [path-to-hook]

set -uo pipefail

HOOK="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../guard-public-posts.sh}"
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$HOOK")/.." && pwd)}"
[ -x "$HOOK" ] || { echo "FATAL: hook not executable: $HOOK" >&2; exit 1; }

# Physical path: the hook compares paths, and $TMPDIR on macOS sits under a
# /var symlink.
FX=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/gpp.XXXXXX")" && pwd -P)
trap 'rm -rf "$FX"' EXIT
unset GH_REPO GH_HOST

mkdir -p "$FX/bin" "$FX/vis"
cat > "$FX/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GPP_FX/gh.log"
if [ "$1" = api ]; then
  shift
  [ "$1" != --hostname ] || shift 2
  f="$GPP_FX/vis/$(printf '%s' "${1#repos/}" | tr / _)"
  [ -f "$f" ] && cat "$f" && exit 0
  echo "gh: could not resolve to a Repository" >&2
  exit 1
fi
exit 0
STUB
chmod +x "$FX/bin/gh"
export GPP_FX="$FX"
export PATH="$FX/bin:$PATH"
printf 'public\n' > "$FX/vis/pub_tool"
printf 'public\n' > "$FX/vis/pub_forked"
printf 'private\n' > "$FX/vis/other_tool"
printf 'private\n' > "$FX/vis/acme-corp_secret-billing"

P="$FX/secret-billing"
git init -q -b main "$P"
git -C "$P" config user.email t@t
git -C "$P" config user.name t
git -C "$P" remote add origin git@github.com:acme-corp/secret-billing.git
printf '{"aiDir":".ai","hooks":{"guardPublicPosts":{"privateIdentifiers":["Project Falcon","/FALC-[0-9]+/"]}}}\n' > "$P/.myspec.json"
printf '.claude/state/\n' > "$P/.gitignore"
git -C "$P" add -A
git -C "$P" commit -q -m init
FIRST=$(git -C "$P" rev-parse HEAD)
git -C "$P" checkout -q -b feat/invoice-rounding
git -C "$P" commit -q --allow-empty -m work
WORK_SHA=$(git -C "$P" rev-parse HEAD)
git -C "$P" checkout -q main
git -C "$P" branch dev
git -C "$P" branch ab
git -C "$P" update-ref refs/remotes/origin/release/2026-q3-cutover "$WORK_SHA"
printf 'Steps: rebase feat/invoice-rounding onto main.\n' > "$P/body.md"
# Ticket keys come from the project: a branch and a commit subject that lead
# with one.
git -C "$P" branch feat/BILL-42-rounding
git -C "$P" checkout -q -b pay-work
git -C "$P" commit -q --allow-empty -m "PAY-3: settle rounding"
git -C "$P" checkout -q main
mkdir -p "$FX/sub"
printf 'see feat/invoice-rounding\n' > "$FX/sub/note.md"

# A public project: what its origin has is public already.
printf 'public\n' > "$FX/vis/pubown_openproj"
Q="$FX/openproj"
git init -q -b main "$Q"
git -C "$Q" config user.email t@t
git -C "$Q" config user.name t
git -C "$Q" remote add origin https://github.com/pubown/openproj.git
git -C "$Q" commit -q --allow-empty -m init
PUSHED=$(git -C "$Q" rev-parse HEAD)
git -C "$Q" update-ref refs/remotes/origin/pushed-topic "$PUSHED"
git -C "$Q" checkout -q -b local-wip-branch
git -C "$Q" commit -q --allow-empty -m local
UNPUSHED=$(git -C "$Q" rev-parse HEAD)
git -C "$Q" checkout -q main

# A fork: origin is private, upstream is the public repo it came from.
F="$FX/fork"
git clone -q "$P" "$F"
git -C "$F" remote set-url origin git@github.com:acme-corp/forked.git
git -C "$F" remote add upstream https://github.com/pub/forked.git
git -C "$F" update-ref refs/remotes/upstream/upstream-topic "$FIRST"
git -C "$F" branch -q private-topic origin/feat/invoice-rounding

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

OUT=""
SID=sess-1
run_in() {  # run_in <cwd> <command>
  : > "$FX/gh.log"
  OUT=$(jq -nc --arg c "$2" --arg d "$1" --arg s "$SID" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d, session_id: $s}' \
    | bash "$HOOK" 2>/dev/null)
}
run() { run_in "$P" "$1"; }
expect_deny() {
  if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then ok; else fail "$1 (not denied: ${OUT:0:160})"; fi
}
expect_quiet() {
  if [ -z "$OUT" ]; then ok; else fail "$1 (denied: $(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason' 2>/dev/null | head -c 300))"; fi
}
expect_reason() {
  if printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason' 2>/dev/null | grep -qF -- "$1"; then ok; else fail "$2 (reason lacks: $1)"; fi
}
expect_no_reason() {
  if printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason' 2>/dev/null | grep -qF -- "$1"; then fail "$2 (reason has: $1)"; else ok; fi
}
api_calls() { grep -c '^api ' "$FX/gh.log" 2>/dev/null || true; }

# --- fast exit ----------------------------------------------------------------
# Without CLAUDE_PLUGIN_ROOT a gh post is denied (the gate is not running), so
# a quiet result for any other command proves it exits before that check.
OUT=$(jq -nc --arg d "$P" '{tool_input: {command: "git status && ls -la"}, cwd: $d}' | env -u CLAUDE_PLUGIN_ROOT bash "$HOOK" 2>/dev/null)
expect_quiet "a command that is not a gh post exits before any check"
OUT=$(jq -nc --arg d "$P" '{tool_input: {command: "gh issue create -R pub/tool --title x"}, cwd: $d}' | env -u CLAUDE_PLUGIN_ROOT bash "$HOOK" 2>/dev/null)
expect_deny "a gh post without the plugin lib is denied"
run "gh pr view 12 && gh issue list -R pub/tool"
expect_quiet "gh reads are not posts"

# --- not a cross-repository public post ---------------------------------------
run 'gh issue create -R acme-corp/secret-billing --title "feat/invoice-rounding" --body "FALC-12"'
expect_quiet "a post to the project's own origin is allowed"
run 'gh pr create --title "feat/invoice-rounding" --body "fixes FALC-12"'
expect_quiet "without -R the post goes to the origin"
run 'gh issue create -R https://github.com/Acme-Corp/Secret-Billing --title x --body "feat/invoice-rounding"'
expect_quiet "the origin given as a URL, in other case, is the origin"
run 'gh issue create -R other/tool --title x --body "see feat/invoice-rounding"'
expect_quiet "a private target is allowed"
run 'gh issue create -R pub/tool --title "hook misfires" --body "A fixture on <app> shows it at <sha>"'
expect_quiet "a clean post to a public target is allowed"
[ "$(api_calls)" = 0 ] && ok || fail "a clean post asks gh nothing (calls: $(api_calls))"
run 'echo "gh issue create -R pub/tool --body feat/invoice-rounding"'
expect_quiet "a gh verb inside quoted text is not a post"
run 'gh api repos/pub/tool/issues --jq ".[].title"'
expect_quiet "gh api GET is not a post"

# --- denied: identifiers from the project --------------------------------------
run 'gh issue create -R pub/tool --title "Cleanup bug" --body "It deleted feat/invoice-rounding by mistake"'
expect_deny "a local branch name is denied"
expect_reason 'branch name "feat/invoice-rounding"' "the reason names the branch"
expect_reason 'fix/some-branch' "the reason gives the placeholder"
expect_reason 'MYSPEC_ALLOW_PUBLIC_POST=1' "the reason names the override"
expect_reason 'github.com/pub/tool (public)' "the reason names the target and its visibility"
run 'gh issue create -R pub/tool --title x --body "cut from release/2026-q3-cutover"'
expect_deny "a remote-tracking branch name is denied"
run "gh issue create -R pub/tool --title x --body 'bisected to ${WORK_SHA:0:9}'"
expect_deny "a short SHA that exists in the project is denied"
expect_reason "commit \"${WORK_SHA:0:9}\"" "the reason names the commit"
run 'gh issue create -R pub/tool --title x --body "the hash deadbeef1234 is not ours"'
expect_quiet "hex that names no commit in the project is allowed"
run 'gh issue create -R pub/tool --title "secret-billing: hook fails" --body x'
expect_deny "the repo name in the title is denied"
expect_reason 'repository name "secret-billing"' "the reason names the repo"
run 'gh issue create -R pub/tool --title x --body "seen in acme-corp only"'
expect_deny "the origin owner is denied"
run 'gh issue create -R pub/tool --title x --body "part of project falcon, see FALC-77"'
expect_deny "configured identifiers are denied"
# BusyBox grep -o prints the pattern's case, GNU and BSD grep the text's.
expect_reason 'alcon" (hooks.guardPublicPosts.privateIdentifiers)' "a configured literal matches case-insensitively"
expect_reason 'private identifier "FALC-77"' "a configured regex matches"
run 'gh issue create -R pub/tool --title x --body "on main and dev the ab test runs; master too"'
expect_quiet "generic and short branch names are not flagged"
run 'gh issue create -R pub/tool --title x --body "log under /Users/jdoe/src; claude.ai/code/session_ABC123"'
expect_deny "a home path and a session link are denied"
expect_reason 'home path "/Users/jdoe"' "the reason names the home path"
expect_reason 'session link' "the reason names the session link"

# --- what is scanned -----------------------------------------------------------
run "gh issue create -R pub/tool --title x --body-file $P/body.md"
expect_deny "the body file is scanned"
run "cd $P && gh issue create -R pub/tool --title x -F body.md"
expect_deny "a relative -F file is read from the directory after cd"
run "gh issue create -R pub/tool --title x --body-file - <<'EOF'
Repro: check out feat/invoice-rounding
EOF"
expect_deny "a heredoc body is scanned"
run "gh issue create -R pub/tool --title x --body \"\$(cat <<'EOF'
Repro on \"feat/invoice-rounding\"
EOF
)\""
expect_deny "a heredoc inside \$(...) in --body is scanned"
run "gh issue create -R pub/tool --title x --body \"\$(cat $P/body.md)\""
expect_deny "\$(cat <file>) inside --body is read"
run 'gh issue comment https://github.com/pub/tool/issues/3 --body "feat/invoice-rounding"'
expect_deny "the URL form names the target"
run 'gh api repos/pub/tool/issues -f title=x -f body="see feat/invoice-rounding"'
expect_deny "gh api POST fields are scanned"
run 'gh api -X PATCH repos/pub/tool/issues/comments/9 -F "body=@body.md"'
expect_deny "gh api -F key=@file is read"
run 'GH_REPO=pub/tool gh issue create --title x --body "feat/invoice-rounding"'
expect_deny "GH_REPO names the target"

# --- override, failure, cache ----------------------------------------------------
run 'MYSPEC_ALLOW_PUBLIC_POST=1 gh issue create -R pub/tool --title x --body "feat/invoice-rounding"'
expect_quiet "the override prefix passes"
run 'gh issue create -R pub/unknown --title x --body "feat/invoice-rounding"'
expect_deny "a target gh cannot resolve is treated as public"
expect_reason 'visibility unknown' "the reason says the visibility is unknown"
NOGH="$FX/nogh"
mkdir -p "$NOGH"
for t in bash jq git awk sed grep sort tr mktemp head cut paste cat dirname rm date tail mkdir env; do
  ln -sf "$(command -v "$t")" "$NOGH/$t"
done
OUT=$(jq -nc --arg d "$P" '{tool_input: {command: "gh issue create -R pub/tool --title x --body feat/invoice-rounding"}, cwd: $d}' \
  | PATH="$NOGH" bash "$HOOK" 2>/dev/null)
expect_quiet "without gh on PATH the post cannot run, so nothing is checked"

SID=sess-cache
run 'gh issue create -R pub/tool --title x --body "feat/invoice-rounding"'
run 'gh issue create -R pub/tool --title y --body "feat/invoice-rounding again"'
expect_deny "the second post is still denied"
[ "$(api_calls)" = 0 ] && ok || fail "the visibility is cached for the session (calls on the second post: $(api_calls))"
grep -q '"t":"visibility"' "$P/.claude/state/sessions/sess-cache.jsonl" 2>/dev/null && ok || fail "the cache is a visibility event in the session-state file"

# --- a fork's upstream ---------------------------------------------------------
run_in "$F" "gh pr create --title x --body 'rebased on upstream-topic at ${FIRST:0:10}'"
expect_quiet "branches and commits the upstream has are public there"
run_in "$F" "gh pr create --title x --body 'from private-topic at ${WORK_SHA:0:10}'"
expect_deny "a fork's own branch and commit are denied when posting upstream"
expect_reason 'github.com/pub/forked' "without -R a fork posts to upstream"

# --- review of #388 ---------------------------------------------------------------
# 1. every subcommand that publishes text
run 'gh pr merge 5 -R pub/tool --squash --subject "Merge feat/invoice-rounding"'
expect_deny "pr merge --subject is scanned"
run 'gh pr merge 5 -R pub/tool -b "from feat/invoice-rounding"'
expect_deny "pr merge --body is scanned"
run 'gh issue reopen 5 -R pub/tool --comment "regressed on feat/invoice-rounding"'
expect_deny "issue reopen --comment is scanned"
run 'gh pr reopen 5 -R pub/tool -c "feat/invoice-rounding"'
expect_deny "pr reopen -c is scanned"
# 2. flags parsed per subcommand
run 'gh pr review 5 -R pub/tool -c -b "see feat/invoice-rounding"'
expect_deny "pr review -c is a boolean; the -b after it is scanned"
run 'gh pr merge 5 -R pub/tool -m -b "feat/invoice-rounding"'
expect_deny "pr merge -m is a boolean; the -b after it is scanned"
# 3. the override counts only on the gh segment itself
run 'gh issue create -R pub/tool --title x --body "MYSPEC_ALLOW_PUBLIC_POST=1 feat/invoice-rounding"'
expect_deny "the override inside the body text does not pass"
run 'MYSPEC_ALLOW_PUBLIC_POST=1 true; gh issue create -R pub/tool --title x --body "feat/invoice-rounding"'
expect_deny "the override on an earlier segment does not pass"
run 'gh issue list; MYSPEC_ALLOW_PUBLIC_POST=1 gh issue create -R pub/tool --title x --body "feat/invoice-rounding"'
expect_quiet "the override as the gh segment's own prefix passes"
run 'env MYSPEC_ALLOW_PUBLIC_POST=1 gh issue create -R pub/tool --title x --body "feat/invoice-rounding"'
expect_quiet "the override through env passes"
# 4. GH_REPO from earlier segments and from the environment
run 'export GH_REPO=pub/tool && gh issue create --title x --body "feat/invoice-rounding"'
expect_deny "export GH_REPO in an earlier segment names the target"
OUT=$(jq -nc --arg d "$P" '{tool_input: {command: "gh issue create --title x --body feat/invoice-rounding"}, cwd: $d}' | GH_REPO=pub/tool bash "$HOOK" 2>/dev/null)
expect_deny "GH_REPO in the environment names the target"
run 'export GH_REPO=pub/tool; unset GH_REPO; gh issue create --title x --body "feat/invoice-rounding"'
expect_quiet "unset GH_REPO drops it"
# 5. gh api attached forms
run 'gh api repos/pub/tool/issues -fbody="feat/invoice-rounding"'
expect_deny "gh api -fk=v is a field"
run 'gh api repos/pub/tool/issues --raw-field=body="feat/invoice-rounding"'
expect_deny "gh api --raw-field=k=v is a field"
run 'gh api repos/pub/tool/issues --field=body=@body.md'
expect_deny "gh api --field=k=@file is read"
run 'gh api repos/pub/tool/issues -Fbody=@body.md'
expect_deny "gh api -Fk=@file is read"
run 'gh api repos/pub/tool/issues --input=body.md'
expect_deny "gh api --input=file is read"
# 6. launchers
run 'env gh issue create -R pub/tool --title x --body "feat/invoice-rounding"'
expect_deny "env gh is a post"
run 'command gh issue create -R pub/tool --title x --body "feat/invoice-rounding"'
expect_deny "command gh is a post"
run 'exec gh issue create -R pub/tool --title x --body "feat/invoice-rounding"'
expect_deny "exec gh is a post"
run 'echo 5 | xargs -n 1 gh issue comment -R pub/tool --body "feat/invoice-rounding"'
expect_deny "xargs gh is a post"
# 7. $(cat file) resolved in the post segment's directory
run "cd $FX/sub && gh issue create -R pub/tool --title x --body \"\$(cat note.md)\"; cd $P"
expect_deny "a relative \$(cat file) is read where the post runs"
# 7b. a substitution splits the post (#385): flags after it still count
run "gh issue create --title x --body \"see \$(cat $P/body.md) here\" -R pub/tool"
expect_deny "-R after a \$(...) in --body names the target"
# shellcheck disable=SC2016 # the command text is the payload; the hook expands nothing
run 'gh issue create -R pub/tool --title x --body "$(printf "%s" "on feat/invoice-rounding")"'
expect_deny "the text a substitution prints is scanned"
# shellcheck disable=SC2016 # the command text is the payload; the hook expands nothing
run 'gh issue create -R pub/tool --title "a (b) c" --body "$(date)"'
expect_quiet "parentheses in a title and a clean substitution are allowed"
# 8. ticket keys: the project's own prefixes only
run 'gh issue create -R pub/tool --title x --body "GPL-3 and PHP-8, see GH-12 and UTF-8"'
expect_quiet "ticket-shaped public names are not flagged"
run 'gh issue create -R pub/tool --title x --body "tracked as BILL-77"'
expect_deny "a ticket key whose prefix a branch carries is denied"
expect_reason 'ticket key "BILL-77"' "the reason names the ticket key"
run 'gh issue create -R pub/tool --title x --body "tracked as PAY-10"'
expect_deny "a ticket key whose prefix leads a commit subject is denied"
# 9. a public project's own pushed identifiers are public
run_in "$Q" "gh issue create -R pub/tool --title x --body 'pubown/openproj on pushed-topic at ${PUSHED:0:10}'"
expect_quiet "a public origin's owner, name, pushed branch and commit are allowed"
run_in "$Q" "gh issue create -R pub/tool --title x --body 'see local-wip-branch'"
expect_deny "a local-only branch of a public project is denied"
run_in "$Q" "gh issue create -R pub/tool --title x --body 'see ${UNPUSHED:0:10}'"
expect_deny "an unpushed commit of a public project is denied"
# 10. a missing lib denies a post and names it
mkdir -p "$FX/partial/lib"
cp "$CLAUDE_PLUGIN_ROOT/lib/hook-core.sh" "$CLAUDE_PLUGIN_ROOT/lib/glob-regex.sh" "$FX/partial/lib/"
OUT=$(jq -nc --arg d "$P" '{tool_input: {command: "gh issue create -R pub/tool --title x"}, cwd: $d}' | CLAUDE_PLUGIN_ROOT="$FX/partial" bash "$HOOK" 2>/dev/null)
expect_deny "a missing command-scan.sh or session-event.sh denies a post"
expect_reason 'command-scan.sh, session-event.sh' "the reason names each missing file"
OUT=$(jq -nc --arg d "$P" '{tool_input: {command: "ls"}, cwd: $d}' | CLAUDE_PLUGIN_ROOT="$FX/partial" bash "$HOOK" 2>/dev/null)
expect_quiet "a missing lib costs no other command"

printf 'guard-public-posts: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
