#!/usr/bin/env bash
# Regression fixture for guard-worktree-context.sh.
#
# Gate A (branch mutations) matches at command position over quote-blanked
# input — more machinery than a grep, and the failure that motivated it (a verb
# inside a commit message blocking the commit) is invisible until something
# exercises it. Gate B (tree-specific commands in worktree mode) reads the
# isolation markers; its cases prove the mode lookup, the inheritance window,
# the recorded-path naming, and the project-level blockInMain extension.
#
# Runs against a synthetic checkout with a real linked worktree, so the
# worktree-targeting cases exercise the actual `git worktree list` lookup.
# Usage: guard-worktree-context.test.sh [path-to-hook]

set -uo pipefail

HOOK="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../guard-worktree-context.sh}"

if [ ! -x "$HOOK" ]; then
  echo "FATAL: hook not executable: $HOOK" >&2
  exit 1
fi

# `pwd -P`: on macOS mktemp returns /var/..., git reports /private/var/...
REPO=$(cd "$(mktemp -d)" && pwd -P)/checkout
mkdir -p "$REPO/.claude/state/isolation"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
git -C "$REPO" commit -q --allow-empty -m init
printf '{"aiDir":".ai","frameworkVersion":"2.0.0","isolation":{"blockInMain":["^make[[:space:]]+deploy([[:space:]]|$)"]}}\n' > "$REPO/.myspec.json"
git -C "$REPO" worktree add -q "$REPO/.claude/worktrees/wt-a" -b wt-a
WT="$REPO/.claude/worktrees/wt-a"
trap 'rm -rf "$(dirname "$REPO")"' EXIT

mark() {  # mark <session-id> <mode> <age-seconds> [worktree-path]
  printf '{"mode":"%s","decided_at":%d,"note":"","worktree_path":"%s"}\n' \
    "$2" "$(( $(date +%s) - $3 ))" "${4:-}" > "$REPO/.claude/state/isolation/$1.json"
}

PASS=0
FAIL=0

run_hook() {  # run_hook <cwd> <session-id> <command> → stdout
  printf '{"tool_input":{"command":%s},"cwd":%s,"session_id":%s}' \
    "$(printf '%s' "$3" | jq -Rs .)" "$(printf '%s' "$1" | jq -Rs .)" "$(printf '%s' "$2" | jq -Rs .)" | "$HOOK"
}

check_in() {  # check_in <cwd> <want> <desc> <session-id> <command>
  local cwd="$1" want="$2" desc="$3" sid="$4" cmd="$5" got out rc
  out=$(run_hook "$cwd" "$sid" "$cmd")
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
    printf 'FAIL  want=%-5s got=%-5s  %s\n      cmd: %s\n      rc=%s stdout: %s\n' \
      "$want" "$got" "$desc" "$cmd" "$rc" "$out" >&2
  fi
}

check() {  # check <want> <desc> <command>   (main checkout, no isolation marker)
  check_in "$REPO" "$1" "$2" none-sess "$3"
}

# --- gate A, must block: real branch mutations at command position ----------
check block "bare checkout"            'git checkout develop'
check block "switch"                   'git switch -c feat/x'
check block "merge"                    'git merge develop'
check block "rebase"                   'git rebase -i origin/develop'
check block "branch rename"            'git branch -m old new'
check block "branch force rename"      'git branch -M old new'
check block "branch copy"              'git branch -c old new'
check block "branch --move"            'git branch --move old new'
check block "branch --copy"            'git branch --copy old new'
check block "after && (cd inside main)"  'cd .claude && git checkout develop'
check block "after ;"                  'echo hi; git merge develop'
check block "after |"                  'true | git checkout develop'
check block "inside then"              'if true; then git checkout develop; fi'
check block "inside subshell"          '(git rebase origin/develop)'
check block "env prefix"               'GIT_PAGER=cat git checkout develop'
check block "checkout -- file"         'git checkout -- package.json'
check block "newline separated"        $'yarn lint\ngit merge develop'

# --- gate A, branch deletion: blocked only when a worktree has it checked out -
# main is checked out in the main checkout, wt-a in the linked worktree.
check allow "delete, not checked out"          'git branch -d feat/x'
check allow "force delete, not checked out"    'git branch -D feat/x'
check allow "--delete, not checked out"        'git branch --delete feat/x'
check allow "--delete --force"                 'git branch --delete --force feat/x'
check allow "-f -d, not checked out"           'git branch -f -d feat/x'
check allow "several names, none checked out"  'git branch -D feat/x feat/y'
check allow "delete after &&"                  'git fetch --prune && git branch -D feat/x'
check block "delete branch of linked worktree" 'git branch -d wt-a'
check block "force delete main-checkout HEAD"  'git branch -D main'
check block "--delete checked-out branch"      'git branch --delete wt-a'
check block "-f -d checked-out branch"         'git branch -f -d wt-a'
check block "one of several is checked out"    'git branch -D feat/x wt-a'
check block "case variant of checked-out name" 'git branch -D WT-A'
check block "names after --"                   'git branch -D -- wt-a'
check block "delete ok, then rename"           'git branch -D feat/x && git branch -m a b'
check block "quoted name cannot be resolved"   'git branch -D "wt-a"'
# shellcheck disable=SC2016 # literal text, not an expansion
check block "variable name cannot be resolved" 'git branch -D $BR'
check block "@{-1} cannot be resolved"         'git branch -d @{-1}'
check block "delete with unknown flag"         'git branch -d --edit-description wt-a'
check allow "remote-tracking -dr"              'git branch -dr origin/feat/x'
check allow "remote-tracking -rd"              'git branch -rd origin/wt-a'
check allow "remote-tracking -Dr"              'git branch -Dr origin/main'
check allow "remote-tracking -d -r"            'git branch -d -r origin/feat/x'
check allow "--delete --remotes"               'git branch --delete --remotes origin/wt-a'

# --- gate A, must allow: the verb appears, but never as a command ------------
check allow "verb in commit message"   'git commit -m "docs: explain that git checkout is blocked"'
check allow "verb in PR body"          'gh pr create --body "then git merge into develop"'
check allow "verb in single quotes"    "grep -r 'git rebase' .claude/"
check allow "separator inside quotes"  'git commit -m "fix; git checkout foo"'
check allow "heredoc prose"            $'cat > x.md <<\'EOF\'\nUse git checkout carefully\nEOF'
check allow "unquoted heredoc prose"   $'cat > x.md <<EOF\nrun git merge here\nEOF'
check allow "echo of the verb"         'echo "git branch -d foo"'

# --- gate A, must allow: safe git usage --------------------------------------
check allow "restore"                  'git restore package.json'
check allow "branch listing"           'git branch --list'
check allow "branch show-current"      'git branch --show-current'
check allow "status"                   'git status --porcelain'
check allow "push"                     'git push origin HEAD'
check allow "log"                      'git log --oneline -5'
check allow "worktree add"             'git worktree add -b feat/x /tmp/wt origin/develop'
check allow "merge-base query"         'git merge-base --is-ancestor abc develop'
check allow "cherry query"             'git cherry develop feat/x'
check allow "sanctioned cleanup"       '.claude/lib/branch-cleanup.sh --branch feat/x'

# --- commands that target a linked worktree are worktree work ----------------
check allow "cd into a worktree, then switch" "cd $WT && git checkout develop"
check allow "git -C a worktree, delete"       "git -C $WT branch -d feat/x"
check block "same verb, no worktree named"    'git checkout develop'

# --- resolved per segment: the cwd, then each cd, then git -C / --git-dir -----
check allow "cd outside any repo, then checkout"   'cd /tmp && git checkout develop'
check block "worktree only mentioned, then checkout" "ls $WT; git checkout develop"
check block "cd scoped to its subshell"            "(cd $WT && git status); git checkout develop"
check_in "$WT" block "cd from a worktree into main"   none-sess "cd $REPO && git checkout develop"
check_in "$WT" block "git -C main from a worktree"    none-sess "git -C $REPO checkout develop"
check_in "$WT" block "--git-dir of main from a worktree" none-sess "git --git-dir=$REPO/.git checkout develop"
check_in "$WT" allow "relative cd staying in the worktree" none-sess "cd . && git checkout develop"

# --- launchers and git global options are looked through ----------------------
check block "git -C main"               "git -C $REPO checkout develop"
check block "git -c key=value"          'git -c core.x=1 checkout develop'
check block "git --no-pager"            'git --no-pager checkout develop'
check block "git -P and -c together"    'git -P -c a.b=c switch develop'
check block "env prefix command"        'env git checkout develop'
check block "env with assignment"       'env GIT_TRACE=1 git merge develop'
check block "command prefix"            'command git checkout develop'
check block "absolute git binary"       '/usr/bin/git checkout develop'
check block "bash -c payload"           "bash -c 'git checkout develop'"
check block "sh -lc payload after cd"   "sh -lc 'cd . && git rebase develop'"
check block "eval payload"              'eval "git checkout develop"'
check allow "bash -c payload in worktree" "bash -c 'cd $WT && git checkout develop'"
check allow "command -v is a lookup"    'command -v git'
check allow "bash -c prose only"        "bash -c 'echo git checkout develop'"

# --- an operation already in progress may be resumed or unwound -------------
check allow "rebase --continue"         'git rebase --continue'
check allow "rebase --abort"            'git rebase --abort'
check allow "rebase --skip"             'git rebase --skip'
check allow "merge --abort"             'git merge --abort'
check allow "merge --continue"          'git merge --continue'
check allow "editor-less continue"      'GIT_EDITOR=true git rebase --continue'
check allow "continue via -c"           'git -c core.editor=true rebase --continue'
check block "rebase --onto is not a resume" 'git rebase --onto main develop'
check block "continue plus a new rebase" 'git rebase --continue && git rebase main'

# --- pull and branch -f move the checked-out branch or a ref -----------------
check block "pull"                      'git pull'
check block "pull --rebase"             'git pull --rebase origin develop'
check block "branch -f"                 'git branch -f feat/x HEAD~1'
check block "branch --force"            'git branch --force feat/x origin/feat/x'
check allow "fetch is not pull"         'git fetch origin'

# --- output contract: silence on allow, deny on block -------------------------
if [ -z "$(run_hook "$REPO" none-sess 'git status')" ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "FAIL  an allowed command must print nothing (approve would skip the permission prompt)" >&2
fi
OUT=$(printf '{"tool_input":{},"cwd":%s,"session_id":"none-sess"}' "$(printf '%s' "$REPO" | jq -Rs .)" | "$HOOK")
RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "FAIL  a payload with no command must pass silently (rc=$RC, stdout: $OUT)" >&2
fi
if run_hook "$REPO" none-sess 'git checkout develop' | jq -e '.hookSpecificOutput.permissionDecision == "deny" and .decision == "block"' >/dev/null; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "FAIL  a block must carry permissionDecision deny plus the legacy decision block" >&2
fi

# --- gate A escape hatch, and gate A holds in develop mode too ---------------
check allow "documented bypass"        'MYSPEC_ALLOW_BRANCH_OPS=1 git checkout develop'
mark dev-sess develop 60
check_in "$REPO" block "develop mode does not lift the branch guard" dev-sess 'git checkout main'

# --- inside a linked worktree everything is approved --------------------------
mark wt-sess worktree 60 "$WT"
check_in "$WT" allow "checkout inside the worktree" wt-sess 'git checkout -b feat/y'
check_in "$WT" allow "build inside the worktree"    wt-sess 'yarn build'

# --- gate B, worktree mode: tree-specific work must not run in the main checkout
mark wt-sess worktree 60 "/tmp/wt/feature-x"
check_in "$REPO" block "build"                wt-sess 'yarn build'
check_in "$REPO" block "npm run build"        wt-sess 'npm run build'
check_in "$REPO" block "pnpm install"         wt-sess 'pnpm install'
check_in "$REPO" block "install"              wt-sess 'yarn install'
check_in "$REPO" block "add a dep"            wt-sess 'yarn add lodash'
check_in "$REPO" block "e2e"                  wt-sess 'yarn test:e2e:mocked'
check_in "$REPO" block "lint:fix"             wt-sess 'yarn lint:fix'
check_in "$REPO" block "npm ci"               wt-sess 'npm ci'
check_in "$REPO" block "pip install"          wt-sess 'pip install -r requirements.txt'
check_in "$REPO" block "cargo build"          wt-sess 'cargo build --release'
check_in "$REPO" block "push"                 wt-sess 'git push origin HEAD'
check_in "$REPO" block "worktree prune"       wt-sess 'git worktree prune'
check_in "$REPO" block "after && (cd inside main)" wt-sess 'cd .claude && yarn build'
check_in "$REPO" block "project blockInMain"  wt-sess 'make deploy'

# Issue #164: build targets and container execs run against the main tree too.
check_in "$REPO" block "yarn build:<target>"          wt-sess 'yarn build:web'
check_in "$REPO" block "npm run build:<target>"       wt-sess 'npm run build:prod'
check_in "$REPO" block "npm run-script build"         wt-sess 'npm run-script build'
check_in "$REPO" block "composer build script"        wt-sess 'composer build'
check_in "$REPO" block "composer run-script build:x"  wt-sess 'composer run-script build:prod'
check_in "$REPO" block "docker compose exec"          wt-sess 'docker compose exec app php artisan migrate'
check_in "$REPO" block "docker-compose exec"          wt-sess 'docker-compose exec app ls'
check_in "$REPO" block "docker compose -f f exec"     wt-sess 'docker compose -f compose.dev.yml exec app ls'
check_in "$REPO" block "docker compose --ansi never exec" wt-sess 'docker compose --ansi never exec -T app ls'
check_in "$REPO" allow "docker compose ps"            wt-sess 'docker compose ps'
check_in "$REPO" allow "docker compose logs"          wt-sess 'docker compose logs app'
check_in "$REPO" allow "exec named as an argument"    wt-sess 'docker compose logs exec'
check_in "$REPO" allow "a script merely named build-ish" wt-sess 'yarn builder'

# Issue #223: a dry-run prune only reports.
check_in "$REPO" allow "worktree prune --dry-run"     wt-sess 'git worktree prune --dry-run'
check_in "$REPO" allow "worktree prune -n"            wt-sess 'git worktree prune -n'
check_in "$REPO" allow "worktree prune -nv"           wt-sess 'git worktree prune -nv'
check_in "$REPO" allow "worktree prune -v --dry-run"  wt-sess 'git worktree prune -v --dry-run'
check_in "$REPO" block "worktree prune -v"            wt-sess 'git worktree prune -v'
check_in "$REPO" block "worktree prune --expire"      wt-sess 'git worktree prune --expire now'
check_in "$REPO" block "dry run, then a real prune"   wt-sess 'git worktree prune -n && git worktree prune'

# --- gate B, worktree mode: these stay allowed on purpose --------------------
check_in "$REPO" allow "read-only lint"       wt-sess 'yarn lint'
check_in "$REPO" allow "dev server"           wt-sess 'yarn dev'
check_in "$REPO" allow "unit tests"           wt-sess 'yarn test:unit'
check_in "$REPO" allow "make test"            wt-sess 'make test'
check_in "$REPO" allow "git status"           wt-sess 'git status --porcelain'
check_in "$REPO" allow "git log"              wt-sess 'git log --oneline -5'
check_in "$REPO" allow "worktree list"        wt-sess 'git worktree list'
check_in "$REPO" allow "build named in prose" wt-sess 'git commit -m "chore: yarn build output"'
check_in "$REPO" allow "documented bypass"    wt-sess 'MYSPEC_ALLOW_MAIN_CHECKOUT=1 yarn install'

# --- gate B: a command that explicitly targets a worktree is already correct --
mark wt-sess worktree 60 "$WT"
check_in "$REPO" allow "cd into the worktree, build" wt-sess "cd $WT && yarn build"
check_in "$REPO" allow "git -C the worktree, push"   wt-sess "git -C $WT push origin HEAD"
check_in "$REPO" block "bare build still blocked"    wt-sess 'yarn build'

# --- develop mode: the main checkout IS the workplace ------------------------
mark dev-sess develop 60
check_in "$REPO" allow "develop mode, build"   dev-sess 'yarn build'
check_in "$REPO" allow "develop mode, install" dev-sess 'yarn install'
check_in "$REPO" allow "develop mode, push"    dev-sess 'git push origin HEAD'

# --- no decision / expired: gate B stays out of the way ----------------------
rm -f "$REPO/.claude/state/isolation/"*.json
check_in "$REPO" allow "no decision recorded"  none-sess 'yarn build'
mark old-sess worktree 30000 "/tmp/wt/old"
check_in "$REPO" allow "expired decision"      old-sess 'yarn build'

# --- issue #146: only a subagent inherits another session's answer ----------
check_as() {  # check_as <want> <desc> <session-id> <command> <extra input fields as JSON>
  local want="$1" desc="$2" sid="$3" cmd="$4" extra="$5" got out rc
  out=$(jq -cn --arg c "$REPO" --arg s "$sid" --arg k "$cmd" --argjson x "$extra" \
    '{tool_input: {command: $k}, cwd: $c, session_id: $s} + $x' | "$HOOK")
  rc=$?
  if printf '%s' "$out" | grep -q '"block"'; then got=block
  elif [ "$rc" -eq 0 ] && [ -z "$out" ]; then got=allow
  else got="noisy"; fi
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL  want=%-5s got=%-5s  %s\n      cmd: %s\n      rc=%s stdout: %s\n' \
      "$want" "$got" "$desc" "$cmd" "$rc" "$out" >&2
  fi
}
rm -f "$REPO/.claude/state/isolation/"*.json
mark other-sess worktree 60 "/tmp/wt/other"
check_as allow "top-level session ignores another session's worktree marker" fresh-sess 'yarn build' '{}'
check_as block "subagent (agent_id) inherits it"         child-sess 'yarn build' '{"agent_id":"a1","agent_type":"general-purpose"}'
check_as block "subagent (agent_type only) inherits it"  child-sess 'yarn build' '{"agent_type":"Explore"}'
check_as allow "empty agent fields are a top-level session" fresh-sess 'yarn build' '{"agent_id":"","agent_type":""}'
mark old-sess worktree 20000 "/tmp/wt/old"
check_as allow "subagent, newest marker past the inherit window" child-sess 'yarn build' '{"agent_id":"a1"}'
rm -f "$REPO/.claude/state/isolation/"*.json

# --- the block names the recorded worktree -----------------------------------
mark path-sess worktree 60 "/tmp/wt/feature-x"
if run_hook "$REPO" path-sess 'yarn build' | grep -q "/tmp/wt/feature-x"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "FAIL  block reason did not name the recorded worktree path" >&2
fi

# --- the branch-guard reason never advertises its bypass ----------------------
if run_hook "$REPO" none-sess 'git checkout develop' | grep -q "MYSPEC_ALLOW_BRANCH_OPS"; then
  FAIL=$((FAIL + 1))
  echo "FAIL  gate A block reason advertises MYSPEC_ALLOW_BRANCH_OPS" >&2
else
  PASS=$((PASS + 1))
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
