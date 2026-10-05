#!/usr/bin/env bash
# Regression fixture for require-isolation-decision.sh.
#
# The distinction under test: EXEMPT_PREFIXES suppress the isolation *prompt*,
# they do not exempt a path from an answer already given. Before that split,
# a worktree-mode session could edit the main checkout's doc tree unchallenged
# — which is the majority of the files a docs-PR session touches. The second
# property is the MAIN_CHECKOUT_ONLY carve-out: session state and the session
# archive have exactly one correct location, whatever the session answered.
#
# Runs against a synthetic checkout in a temp dir; never touches a real repo.
# Usage: require-isolation-decision.test.sh [path-to-hook]

set -uo pipefail

HOOK="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../require-isolation-decision.sh}"
# The hooks find their lib through CLAUDE_PLUGIN_ROOT, as the harness exports it.
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$HOOK")/.." && pwd)}"

if [ ! -x "$HOOK" ]; then
  echo "FATAL: hook not executable: $HOOK" >&2
  exit 1
fi

# `pwd -P` matters: on macOS mktemp hands back /var/..., git reports
# /private/var/..., and the hook's prefix strip would then treat every path as
# living outside the repo and approve it.
ROOT=$(cd "$(mktemp -d)" && pwd -P)
REPO="$ROOT/checkout"
STATE="$REPO/.claude/state/sessions"
mkdir -p "$STATE"
git init -q -b main "$REPO"
printf '{"aiDir":".ai","frameworkVersion":"2.0.0"}\n' > "$REPO/.myspec.json"
trap 'rm -rf "$ROOT"' EXIT

mark() {  # mark <session-id> <mode> <age-seconds>: an isolation event that old
  printf '{"t":"isolation","mode":"%s","path":"","note":"","at":%d}\n' \
    "$2" "$(( $(date +%s) - $3 ))" >> "$STATE/$1.jsonl"
}

PASS=0
FAIL=0

run_hook() {  # run_hook <cwd> <session-id> <file-path> → stdout
  printf '{"tool_input":{"file_path":%s},"cwd":%s,"session_id":%s}' \
    "$(printf '%s' "$3" | jq -Rs .)" "$(printf '%s' "$1" | jq -Rs .)" "$(printf '%s' "$2" | jq -Rs .)" | "$HOOK"
}

check() {  # check <want> <desc> <session-id> <file-path>
  local want="$1" desc="$2" sid="$3" file="$4" got out rc
  out=$(run_hook "$REPO" "$sid" "$file")
  rc=$?

  # An allow is exit 0 with EMPTY stdout. Anything printed on allow is a
  # defect: {"decision": "approve"} is the deprecated PreToolUse spelling of
  # "allow", which skips the user's permission prompt (issue #158).
  if printf '%s' "$out" | grep -q '"deny"'; then got=block
  elif [ "$rc" -eq 0 ] && [ -z "$out" ]; then got=allow
  else got="noisy"; fi

  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL  want=%-5s got=%-5s  %s (%s)\n      rc=%s stdout: %s\n' \
      "$want" "$got" "$desc" "$file" "$rc" "$out" >&2
  fi
}

# --- worktree mode: main-checkout edits are blocked, docs included -----------
mark wt-sess worktree 60
check block "worktree mode, source file"   wt-sess "$REPO/components/Foo.vue"
check block "worktree mode, aiDir doc"     wt-sess "$REPO/.ai/features/x/spec.md"
check block "worktree mode, .claude rule"  wt-sess "$REPO/.claude/rules/paths.md"
check block "worktree mode, CLAUDE.md"     wt-sess "$REPO/CLAUDE.md"
check allow "worktree mode, outside repo"  wt-sess "/tmp/scratch/notes.md"

# --- a file inside a LINKED WORKTREE is never a main-checkout edit ----------
git -C "$REPO" commit -q --allow-empty -m init
git -C "$REPO" worktree add -q "$REPO/.claude/worktrees/wt-a" -b wt-a
mkdir -p "$REPO/.claude/worktrees/wt-a/components"
mark wt-sess worktree 60
check allow "worktree file, source"        wt-sess "$REPO/.claude/worktrees/wt-a/components/Foo.vue"
check allow "worktree file, doc"           wt-sess "$REPO/.claude/worktrees/wt-a/.ai/features/x/spec.md"
check allow "worktree file, workflow"      wt-sess "$REPO/.claude/worktrees/wt-a/.github/workflows/ci.yml"
check block "main checkout still blocked"  wt-sess "$REPO/components/Foo.vue"

# --- develop mode: everything in the main checkout is fine ------------------
mark dev-sess develop 60
check allow "develop mode, source file"    dev-sess "$REPO/components/Foo.vue"
check allow "develop mode, aiDir doc"      dev-sess "$REPO/.ai/features/x/spec.md"

# --- expired decision falls through to the ask ------------------------------
mark old-sess develop 30000
check block "expired decision, source"     old-sess "$REPO/server/api/foo.js"

# --- no decision: exempt paths never prompt, source paths do ----------------
rm -f "$STATE/"*.jsonl
check allow "no decision, aiDir doc"       new-sess "$REPO/.ai/features/x/spec.md"
check allow "no decision, .claude file"    new-sess "$REPO/.claude/settings.json"
check allow "no decision, docs/ file"      new-sess "$REPO/docs/guide.md"
check allow "no decision, CLAUDE.md"       new-sess "$REPO/CLAUDE.md"
check block "no decision, source file"     new-sess "$REPO/components/Foo.vue"
check block "no decision, config file"     new-sess "$REPO/vite.config.js"

# The ask names the session id, the worktree root, and the detected base branch
# (no remote here, so the documented fallback). The recorder is named by its
# path under the plugin's lib/: the model runs the line through Bash, where
# CLAUDE_PLUGIN_ROOT is not set, so a variable or a project path would fail.
OUT=$(run_hook "$REPO" new-sess "$REPO/components/Foo.vue" | jq -r '.hookSpecificOutput.permissionDecisionReason')
for needle in "\"$CLAUDE_PLUGIN_ROOT/lib/set-isolation.sh\" new-sess develop" "\"$CLAUDE_PLUGIN_ROOT/lib/set-isolation.sh\" --show" "\"$CLAUDE_PLUGIN_ROOT/lib/set-isolation.sh\" --reset new-sess" "\"$CLAUDE_PLUGIN_ROOT/lib/promote-to-worktree.sh\" --branch" '.claude/worktrees/' '.ai/work-isolation.md'; do
  if printf '%s' "$OUT" | grep -qF -- "$needle"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL  ask does not mention: $needle" >&2; fi
done
if printf '%s' "$OUT" | grep -qF -- '.claude/lib/'; then FAIL=$((FAIL + 1)); echo "FAIL  the ask names a project-local lib copy" >&2; else PASS=$((PASS + 1)); fi
# The always-loaded rule is only the contract since #226; the heuristic and the
# procedure live in the aiDir reference file, so no block may send the model
# back to the rule for them.
if printf '%s' "$OUT" | grep -qF '.claude/rules/work-isolation.md'; then FAIL=$((FAIL + 1)); echo "FAIL  ask cites the rule, not the procedure file" >&2; else PASS=$((PASS + 1)); fi
mark wt-sess worktree 60
OUT=$(run_hook "$REPO" wt-sess "$REPO/components/Foo.vue")
if printf '%s' "$OUT" | grep -qF 'origin/main'; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL  worktree block does not name the base branch fallback" >&2; fi
if printf '%s' "$OUT" | grep -qF 'Full procedure: .ai/work-isolation.md'; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL  worktree block does not cite the procedure file" >&2; fi

# --- per-checkout state and the session archive are pinned to the main checkout
mark wt-sess worktree 60
mark dev-sess develop 60
check allow "worktree mode, live session log"   wt-sess "$REPO/.claude/state/sessions/abc123.md"
check allow "worktree mode, session-state file" wt-sess "$REPO/.claude/state/sessions/abc123.jsonl"
check allow "worktree mode, archived session"   wt-sess "$REPO/.ai/memory/sessions/archive/2026-08-31-x.md"
check allow "develop mode, live session log"    dev-sess "$REPO/.claude/state/sessions/abc123.md"

# The carve-out is narrow — every other memory path is a committed doc and
# still obeys a worktree answer.
check block "worktree mode, memory entry"        wt-sess "$REPO/.ai/memory/semantic/S090-thing.md"
check block "worktree mode, memory index"        wt-sess "$REPO/.ai/memory/index.md"
check block "worktree mode, sessions lookalike"  wt-sess "$REPO/.ai/memory/sessions-notes.md"
check block "worktree mode, other .claude file"  wt-sess "$REPO/.claude/rules/paths.md"

# --- a configured aiDir moves the exemption with it ---------------------------
rm -f "$STATE/"*.jsonl
printf '{"aiDir":"docs/ai","frameworkVersion":"2.0.0"}\n' > "$REPO/.myspec.json"
check allow "no decision, configured aiDir doc"  new-sess "$REPO/docs/ai/features/x/spec.md"
check block "no decision, the old .ai path is source now" new-sess "$REPO/.ai/thing.js"

# --- output contract: silence on allow, deny on block -------------------------
rm -f "$STATE/"*.jsonl
# Since 3.0 the deny is the hookSpecificOutput form alone: the top-level
# decision/reason pair is the deprecated PreToolUse spelling, dropped with
# the host floor (#266).
if run_hook "$REPO" new-sess "$REPO/components/Foo.vue" | jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | length > 0) and (has("decision") or has("reason") | not)' >/dev/null; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL  a block must carry permissionDecision deny with its reason, and no legacy decision/reason pair" >&2
fi
mark dev-sess develop 60
if [ -z "$(run_hook "$REPO" dev-sess "$REPO/components/Foo.vue")" ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL  an allowed edit must print nothing (approve would skip the permission prompt)" >&2
fi

# --- not a myspec project: the hook stays out of the way ----------------------
OTHER="$ROOT/other"
git init -q -b main "$OTHER"
OUT=$(printf '{"tool_input":{"file_path":%s},"cwd":%s,"session_id":"x"}' \
     "$(printf '%s' "$OTHER/src/a.ts" | jq -Rs .)" "$(printf '%s' "$OTHER" | jq -Rs .)" | "$HOOK")
RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL  a repo without .myspec.json must pass silently (rc=$RC, stdout: $OUT)" >&2
fi

# --- cwd and agent identity ---------------------------------------------------
# check_as <want> <desc> <cwd> <session-id> <file> [extra input fields as JSON]
check_as() {
  local want="$1" desc="$2" cwd="$3" sid="$4" file="$5" extra='{}' got out rc
  [ "$#" -lt 6 ] || extra="$6"
  out=$(jq -cn --arg f "$file" --arg c "$cwd" --arg s "$sid" --argjson x "$extra" \
    '{tool_input: {file_path: $f}, cwd: $c, session_id: $s} + $x' | "$HOOK")
  rc=$?
  if printf '%s' "$out" | grep -q '"deny"'; then got=block
  elif [ "$rc" -eq 0 ] && [ -z "$out" ]; then got=allow
  else got="noisy"; fi
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL  want=%-5s got=%-5s  %s (%s)\n      rc=%s stdout: %s\n' \
      "$want" "$got" "$desc" "$file" "$rc" "$out" >&2
  fi
}

printf '{"aiDir":".ai","frameworkVersion":"2.0.0"}\n' > "$REPO/.myspec.json"
cp "$REPO/.myspec.json" "$REPO/.claude/worktrees/wt-a/.myspec.json"
WTA="$REPO/.claude/worktrees/wt-a"

# Issue #224: a cwd inside a linked worktree says nothing about the edited
# file. A main-checkout path is still judged against the session's answer.
rm -f "$STATE/"*.jsonl
mark wt-sess worktree 60
check_as block "cwd in worktree, worktree mode, main-checkout file" "$WTA" wt-sess "$REPO/components/Foo.vue"
check_as block "cwd in worktree, worktree mode, main-checkout doc"  "$WTA" wt-sess "$REPO/.ai/features/x/spec.md"
check_as allow "cwd in worktree, worktree mode, worktree file"      "$WTA" wt-sess "$WTA/components/Foo.vue"
check_as allow "cwd in worktree, relative path stays in the worktree" "$WTA" wt-sess "components/Foo.vue"
check_as allow "cwd in worktree, main-checkout session log"         "$WTA" wt-sess "$REPO/.claude/state/sessions/abc.md"
mark dev-sess develop 60
check_as allow "cwd in worktree, develop mode, main-checkout file"  "$WTA" dev-sess "$REPO/components/Foo.vue"
rm -f "$STATE/"*.jsonl
check_as block "cwd in worktree, no decision, main-checkout source" "$WTA" new-sess "$REPO/components/Foo.vue"

# Issue #146: no session is handed another session's decision. A subagent
# shares its parent's session id (#225), so it reads the parent's decision
# from the same file; one with another id has no decision either.
rm -f "$STATE/"*.jsonl
mark other-sess worktree 60
check_as allow "top-level, another session chose worktree, doc edit" "$REPO" fresh-sess "$REPO/.ai/features/x/spec.md"
check_as block "top-level, another session chose worktree, source asks"  "$REPO" fresh-sess "$REPO/components/Foo.vue"
if jq -cn --arg f "$REPO/components/Foo.vue" --arg c "$REPO" '{tool_input: {file_path: $f}, cwd: $c, session_id: "fresh-sess"}' | "$HOOK" | grep -qF 'no work-isolation decision'; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL  a top-level session without a decision must get the ask, not an inherited block" >&2
fi
check_as block "subagent sharing the parent id follows worktree"  "$REPO" other-sess "$REPO/.ai/features/x/spec.md" '{"agent_id":"a1","agent_type":"general-purpose"}'
check_as allow "subagent with another id inherits nothing (doc)" "$REPO" child-sess "$REPO/.ai/features/x/spec.md" '{"agent_id":"a1","agent_type":"general-purpose"}'
if jq -cn --arg f "$REPO/components/Foo.vue" --arg c "$REPO" '{tool_input: {file_path: $f}, cwd: $c, session_id: "child-sess", agent_id: "a1"}' | "$HOOK" | grep -qF 'no work-isolation decision'; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL  a subagent with another session id must not inherit the newest decision (step 7)" >&2
fi
rm -f "$STATE/"*.jsonl
mark other-sess develop 60
check_as block "top-level, another session chose develop, source asks" "$REPO" fresh-sess "$REPO/components/Foo.vue"
check_as block "subagent with another id does not inherit develop" "$REPO" child-sess "$REPO/components/Foo.vue" '{"agent_type":"myspec:probe-executor"}'
check_as allow "subagent sharing the parent id uses it"     "$REPO" other-sess "$REPO/components/Foo.vue" '{"agent_id":"a1"}'
check_as block "empty agent_id is not a subagent"           "$REPO" fresh-sess "$REPO/components/Foo.vue" '{"agent_id":""}'

# A file_path spelled through a symlink (a linked home directory, macOS /tmp)
# is the same file. Git reports the physical toplevel, so the hook used to
# miss the repo prefix and approve the edit as outside the repo.
LINKED="$ROOT/linked-checkout"
ln -s "$REPO" "$LINKED"
rm -f "$STATE/"*.jsonl
check_as block "symlinked path, no decision, source asks"       "$LINKED" link-sess "$LINKED/components/Foo.vue"
check_as block "symlinked path, cwd physical, no decision"      "$REPO"   link-sess "$LINKED/components/Foo.vue"
mark link-sess worktree 60
check_as block "symlinked path, worktree mode, main-checkout file" "$LINKED" link-sess "$LINKED/components/Foo.vue"
check_as allow "symlinked path, worktree mode, worktree file"   "$LINKED" link-sess "$LINKED/.claude/worktrees/wt-a/components/Foo.vue"
rm -f "$STATE/"*.jsonl
mark link-sess develop 60
check_as allow "symlinked path, develop mode"                  "$LINKED" link-sess "$LINKED/components/Foo.vue"
check_as allow "symlinked path outside the repo"               "$LINKED" link-sess "$ROOT/elsewhere/a.ts"

# An ancestor directory that cannot be entered (mode 0644): physical_path
# fails, and under set -e the hook exited 1, which lets the edit through.
mkdir -p "$REPO/locked/sub"
chmod 0644 "$REPO/locked"
rm -f "$STATE/"*.jsonl
check_as block "unenterable ancestor, no decision, source asks" "$REPO" lock-sess "$REPO/locked/sub/x.ts"
chmod 0755 "$REPO/locked"

# The 2.x isolation marker (.claude/state/isolation/<sid>.json, written by
# the 2.x set-isolation.sh) is not read since 3.0 (#266: no import shim):
# a session that spans the upgrade is asked again, and the marker is left
# where it is for the user to delete.
rm -f "$STATE/"*.jsonl
mkdir -p "$REPO/.claude/state/isolation"
printf '{"mode":"develop","decided_at":%d,"note":"","worktree_path":""}\n' "$(date +%s)" > "$REPO/.claude/state/isolation/old-sess.json"
check_as block "2.x isolation marker, develop: not read, the hook asks" "$REPO" old-sess "$REPO/components/Foo.vue"
if jq -cn --arg f "$REPO/components/Foo.vue" --arg c "$REPO" '{tool_input: {file_path: $f}, cwd: $c, session_id: "old-sess"}' | "$HOOK" | grep -qF 'no work-isolation decision'; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL  a 2.x marker blocks with the ask, not with an imported decision" >&2
fi
if [ -f "$REPO/.claude/state/isolation/old-sess.json" ] && [ ! -e "$REPO/.claude/state/isolation/old-sess.json.imported" ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL  the 2.x marker is left in place, not renamed .imported" >&2
fi

# The real writer: set-isolation.sh records, --reset re-asks.
SET_ISO="$(cd "$(dirname "$HOOK")" && pwd)/../lib/set-isolation.sh"
rm -f "$STATE/"*.jsonl
(cd "$REPO" && bash "$SET_ISO" real-sess worktree >/dev/null)
check_as block "set-isolation worktree: main-checkout source blocked" "$REPO" real-sess "$REPO/components/Foo.vue"
check_as block "set-isolation worktree, from a subagent of the session" "$WTA" real-sess "$REPO/components/Foo.vue" '{"agent_id":"a9"}'
(cd "$REPO" && bash "$SET_ISO" --reset real-sess >/dev/null)
if jq -cn --arg f "$REPO/components/Foo.vue" --arg c "$REPO" '{tool_input: {file_path: $f}, cwd: $c, session_id: "real-sess"}' | "$HOOK" | grep -qF 'no work-isolation decision'; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL  after --reset the next source edit asks again" >&2
fi

# --- an empty worktreeRoot never opens the gate (#275 review) ------------------
# The value only names where worktrees go; the schema default stands in.
cp "$REPO/.myspec.json" "$ROOT/myspec.saved"
printf '{"aiDir":".ai","frameworkVersion":"3.0.0","isolation":{"worktreeRoot":""}}\n' > "$REPO/.myspec.json"
rm -f "$STATE/"*.jsonl
check block "worktreeRoot \"\", no decision, source file" empty-root "$REPO/components/Foo.vue"
if run_hook "$REPO" empty-root "$REPO/components/Foo.vue" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -qF '.claude/worktrees/'; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL  with worktreeRoot \"\" the ask names the default root" >&2
fi
cp "$ROOT/myspec.saved" "$REPO/.myspec.json"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
