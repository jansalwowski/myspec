#!/usr/bin/env bash
# Regression fixture for guard-git-branch.sh.
#
# The hook matches at command position over quote-blanked input. That is more
# machinery than a grep, so it needs a fixture: the failure that motivated it
# (a verb inside a commit message blocking the commit) is invisible until
# something exercises it.
#
# Usage: guard-git-branch.test.sh [path-to-hook] [repo-root]
# Exits non-zero on the first mismatch.

set -uo pipefail

HOOK="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../guard-git-branch.sh}"
REPO="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"

if [ ! -x "$HOOK" ]; then
  echo "FATAL: hook not executable: $HOOK" >&2
  exit 1
fi

# The hook approves everything inside a worktree, so the fixture must run
# against a main checkout to exercise the blocklist at all.
if [ -f "$REPO/.git" ]; then
  echo "FATAL: repo root is a worktree; pass a main checkout as \$2" >&2
  exit 1
fi

PASS=0
FAIL=0

check() {
  local want="$1" desc="$2" cmd="$3" got out
  out=$(printf '{"tool_input":{"command":%s},"cwd":%s}' \
        "$(printf '%s' "$cmd" | jq -Rs .)" "$(printf '%s' "$REPO" | jq -Rs .)" | "$HOOK")

  if printf '%s' "$out" | grep -q '"block"'; then got=block; else got=allow; fi

  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL  want=%-5s got=%-5s  %s\n      cmd: %s\n' "$want" "$got" "$desc" "$cmd" >&2
  fi
}

# --- must block: real branch mutations at command position ------------------
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

# --- must allow: the verb appears, but never as a command -------------------
check allow "verb in commit message"   'git commit -m "docs: explain that git checkout is blocked"'
check allow "verb in PR body"          'gh pr create --body "then git merge into develop"'
check allow "verb in single quotes"    "grep -r 'git rebase' .claude/"
check allow "separator inside quotes"  'git commit -m "fix; git checkout foo"'
check allow "heredoc prose"            $'cat > x.md <<\'EOF\'\nUse git checkout carefully\nEOF'
check allow "unquoted heredoc prose"   $'cat > x.md <<EOF\nrun git merge here\nEOF'
check allow "echo of the verb"         'echo "git branch -d foo"'

# --- must allow: safe git usage --------------------------------------------
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

# --- escape hatch -----------------------------------------------------------
check allow "documented bypass"        'MYSPEC_ALLOW_BRANCH_OPS=1 git branch -d feat/x'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
