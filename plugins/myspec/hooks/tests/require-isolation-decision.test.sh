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

if [ ! -x "$HOOK" ]; then
  echo "FATAL: hook not executable: $HOOK" >&2
  exit 1
fi

# `pwd -P` matters: on macOS mktemp hands back /var/..., git reports
# /private/var/..., and the hook's prefix strip would then treat every path as
# living outside the repo and approve it.
ROOT=$(cd "$(mktemp -d)" && pwd -P)
REPO="$ROOT/checkout"
mkdir -p "$REPO/.claude/state/isolation"
git init -q -b main "$REPO"
printf '{"aiDir":".ai","frameworkVersion":"2.0.0"}\n' > "$REPO/.myspec.json"
trap 'rm -rf "$ROOT"' EXIT

mark() {  # mark <session-id> <mode> <age-seconds>
  printf '{"mode":"%s","decided_at":%d,"note":""}\n' \
    "$2" "$(( $(date +%s) - $3 ))" > "$REPO/.claude/state/isolation/$1.json"
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
  if printf '%s' "$out" | grep -q '"block"'; then got=block
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
rm -f "$REPO/.claude/state/isolation/"*.json
check allow "no decision, aiDir doc"       new-sess "$REPO/.ai/features/x/spec.md"
check allow "no decision, .claude file"    new-sess "$REPO/.claude/settings.json"
check allow "no decision, docs/ file"      new-sess "$REPO/docs/guide.md"
check allow "no decision, CLAUDE.md"       new-sess "$REPO/CLAUDE.md"
check block "no decision, source file"     new-sess "$REPO/components/Foo.vue"
check block "no decision, config file"     new-sess "$REPO/vite.config.js"

# The ask names the session id, the worktree root, and the detected base branch
# (no remote here, so the documented fallback).
OUT=$(run_hook "$REPO" new-sess "$REPO/components/Foo.vue")
for needle in 'set-isolation.sh new-sess develop' '.claude/worktrees/' '.ai/work-isolation.md'; do
  if printf '%s' "$OUT" | grep -qF -- "$needle"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL  ask does not mention: $needle" >&2; fi
done
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
check allow "worktree mode, isolation marker"   wt-sess "$REPO/.claude/state/isolation/abc123.json"
check allow "worktree mode, archived session"   wt-sess "$REPO/.ai/memory/sessions/archive/2026-08-31-x.md"
check allow "develop mode, live session log"    dev-sess "$REPO/.claude/state/sessions/abc123.md"

# The carve-out is narrow — every other memory path is a committed doc and
# still obeys a worktree answer.
check block "worktree mode, memory entry"        wt-sess "$REPO/.ai/memory/semantic/S090-thing.md"
check block "worktree mode, memory index"        wt-sess "$REPO/.ai/memory/index.md"
check block "worktree mode, sessions lookalike"  wt-sess "$REPO/.ai/memory/sessions-notes.md"
check block "worktree mode, other .claude file"  wt-sess "$REPO/.claude/rules/paths.md"

# --- a configured aiDir moves the exemption with it ---------------------------
rm -f "$REPO/.claude/state/isolation/"*.json
printf '{"aiDir":"docs/ai","frameworkVersion":"2.0.0"}\n' > "$REPO/.myspec.json"
check allow "no decision, configured aiDir doc"  new-sess "$REPO/docs/ai/features/x/spec.md"
check block "no decision, the old .ai path is source now" new-sess "$REPO/.ai/thing.js"

# --- output contract: silence on allow, deny on block -------------------------
rm -f "$REPO/.claude/state/isolation/"*.json
if run_hook "$REPO" new-sess "$REPO/components/Foo.vue" | jq -e '.hookSpecificOutput.permissionDecision == "deny" and .decision == "block"' >/dev/null; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL  a block must carry permissionDecision deny plus the legacy decision block" >&2
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
  if printf '%s' "$out" | grep -q '"block"'; then got=block
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
rm -f "$REPO/.claude/state/isolation/"*.json
mark wt-sess worktree 60
check_as block "cwd in worktree, worktree mode, main-checkout file" "$WTA" wt-sess "$REPO/components/Foo.vue"
check_as block "cwd in worktree, worktree mode, main-checkout doc"  "$WTA" wt-sess "$REPO/.ai/features/x/spec.md"
check_as allow "cwd in worktree, worktree mode, worktree file"      "$WTA" wt-sess "$WTA/components/Foo.vue"
check_as allow "cwd in worktree, relative path stays in the worktree" "$WTA" wt-sess "components/Foo.vue"
check_as allow "cwd in worktree, main-checkout session log"         "$WTA" wt-sess "$REPO/.claude/state/sessions/abc.md"
mark dev-sess develop 60
check_as allow "cwd in worktree, develop mode, main-checkout file"  "$WTA" dev-sess "$REPO/components/Foo.vue"
rm -f "$REPO/.claude/state/isolation/"*.json
check_as block "cwd in worktree, no decision, main-checkout source" "$WTA" new-sess "$REPO/components/Foo.vue"

# Issue #146: only a subagent inherits the newest marker. A top-level session
# (no agent_id / agent_type) with no marker of its own is asked.
rm -f "$REPO/.claude/state/isolation/"*.json
mark other-sess worktree 60
check_as allow "top-level, another session chose worktree, doc edit" "$REPO" fresh-sess "$REPO/.ai/features/x/spec.md"
check_as block "top-level, another session chose worktree, source asks"  "$REPO" fresh-sess "$REPO/components/Foo.vue"
if jq -cn --arg f "$REPO/components/Foo.vue" --arg c "$REPO" '{tool_input: {file_path: $f}, cwd: $c, session_id: "fresh-sess"}' | "$HOOK" | grep -qF 'no work-isolation decision'; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL  a top-level session without a marker must get the ask, not an inherited block" >&2
fi
check_as block "subagent (agent_id) inherits worktree"      "$REPO" child-sess "$REPO/.ai/features/x/spec.md" '{"agent_id":"a1","agent_type":"general-purpose"}'
check_as block "subagent (agent_type only) inherits worktree" "$REPO" child-sess "$REPO/.ai/features/x/spec.md" '{"agent_type":"myspec:probe-executor"}'
rm -f "$REPO/.claude/state/isolation/"*.json
mark other-sess develop 60
check_as block "top-level, another session chose develop, source asks" "$REPO" fresh-sess "$REPO/components/Foo.vue"
check_as allow "subagent inherits develop"                  "$REPO" child-sess "$REPO/components/Foo.vue" '{"agent_id":"a1"}'
check_as allow "subagent sharing the parent id uses it"     "$REPO" other-sess "$REPO/components/Foo.vue" '{"agent_id":"a1"}'
check_as block "empty agent_id is not a subagent"           "$REPO" fresh-sess "$REPO/components/Foo.vue" '{"agent_id":""}'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
