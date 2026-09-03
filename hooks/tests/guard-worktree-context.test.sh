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
  local cwd="$1" want="$2" desc="$3" sid="$4" cmd="$5" got out
  out=$(run_hook "$cwd" "$sid" "$cmd")

  if printf '%s' "$out" | grep -q '"block"'; then got=block; else got=allow; fi

  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL  want=%-5s got=%-5s  %s\n      cmd: %s\n' "$want" "$got" "$desc" "$cmd" >&2
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
check block "branch delete"            'git branch -d feat/x'
check block "branch force delete"      'git branch -D feat/x'
check block "branch rename"            'git branch -m old new'
check block "after &&"                 'cd /tmp && git checkout develop'
check block "after ;"                  'echo hi; git merge develop'
check block "after |"                  'true | git checkout develop'
check block "inside then"              'if true; then git checkout develop; fi'
check block "inside subshell"          '(git rebase origin/develop)'
check block "env prefix"               'GIT_PAGER=cat git checkout develop'
check block "checkout -- file"         'git checkout -- package.json'
check block "newline separated"        $'yarn lint\ngit merge develop'

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

# --- gate A escape hatch, and gate A holds in develop mode too ---------------
check allow "documented bypass"        'MYSPEC_ALLOW_BRANCH_OPS=1 git branch -d feat/x'
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
check_in "$REPO" block "after &&"             wt-sess 'cd /tmp && yarn build'
check_in "$REPO" block "project blockInMain"  wt-sess 'make deploy'

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
