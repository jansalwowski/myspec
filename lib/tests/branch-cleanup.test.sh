#!/usr/bin/env bash
# Regression fixture for branch-cleanup.sh.
#
# The script is allowed to use `git branch -D`, which discards git's own
# unmerged-branch protection. Everything that keeps that safe lives in
# classify(), so classify() needs a fixture that models the ways a branch can
# look merged without being merged.
#
# Builds a synthetic repo with a squash-merge history and no network. Proof B
# (merged PR whose head contains the tip) runs against a stub `gh` on PATH
# that answers from JSON files; proofs A and C and every veto are exercised.
#
# Usage: branch-cleanup.test.sh [path-to-script]

set -uo pipefail

SCRIPT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../branch-cleanup.sh}"
# shellcheck source=lib/tests/old-bash.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/old-bash.sh"

if [ ! -x "$SCRIPT" ]; then
  echo "FATAL: script not executable: $SCRIPT" >&2
  exit 1
fi

ROOT=$(cd "$(mktemp -d)" && pwd -P)
REPO="$ROOT/repo"
mkdir -p "$REPO"
trap 'rm -rf "$ROOT"' EXIT

cd "$REPO" || exit 1
git init -q -b develop .
git config user.email t@t
git config user.name t

seed() { echo "$2" > "$1"; git add -A; git commit -qm "$3"; }
seed base.txt base init

git clone -q --bare . "$ROOT/origin.git"
git remote add origin "$ROOT/origin.git"
git push -q -u origin develop

mkbranch() { git checkout -q -b "$1" develop; }
squash_merge() {
  git checkout -q develop
  git merge -q --squash "$1" >/dev/null 2>&1 || true
  git commit -qm "squash: $1 (#999)"
}

# 1. plain ancestor merge
mkbranch ff-merged;               seed a.txt A "add a"
git checkout -q develop; git merge -q --ff-only ff-merged

# 2. squash-merged, nothing after it
mkbranch squash-clean;            seed b.txt B1 b1; seed b2.txt B2 b2
squash_merge squash-clean

# 3. squash-merged, then more work pushed
mkbranch squash-then-more;        seed c.txt C1 c1
squash_merge squash-then-more
git checkout -q squash-then-more; seed c.txt C2-UNMERGED c2

# 4. never merged at all
mkbranch never-merged;            seed d.txt D d

# 5. squash-merged, then the base moved on over the same file
mkbranch base-moved;              seed e.txt E1 e1
squash_merge base-moved
git checkout -q develop;          seed e.txt E1-later "later edit"

# 6. content merged but the branch was never pushed
mkbranch unpushed;                seed f.txt F f
squash_merge unpushed

# 10. commits cherry-picked into the base, then the base moved on.
#     Neither A (content drifts) nor B (no PR in this fixture) can see this.
mkbranch picked;                  seed p.txt P1 "p1"
PICKED_SHA=$(git rev-parse HEAD)
git checkout -q develop
# Advance the base FIRST, so the branch is not merely an ancestor — otherwise
# the cheap ancestor test clears it and the case proves nothing about C.
seed diverge.txt D "base advances independently"
git cherry-pick "$PICKED_SHA" >/dev/null 2>&1
seed p.txt P1-later "later edit on the base"

# 11. one commit cherry-picked, one still only on the branch.
mkbranch picked-plus;             seed q.txt Q1 "q1"
PICKED_PLUS_SHA=$(git rev-parse HEAD)
git checkout -q develop
seed diverge2.txt D2 "base advances independently"
git cherry-pick "$PICKED_PLUS_SHA" >/dev/null 2>&1
git checkout -q picked-plus;      seed q2.txt Q2 "q2 never merged"

# 7 + 8. merged branches that own a worktree
mkbranch wt-clean;                seed g.txt G g
squash_merge wt-clean
mkbranch wt-dirty;                seed h.txt H h
squash_merge wt-dirty

git checkout -q develop
for b in ff-merged squash-clean squash-then-more never-merged base-moved wt-clean wt-dirty picked picked-plus; do
  git push -q origin "$b" 2>/dev/null || true
done

git worktree add -q "$ROOT/wt-clean" wt-clean
git worktree add -q "$ROOT/wt-dirty" wt-dirty
echo "scratch notes" > "$ROOT/wt-dirty/NOTES.txt"

# A worktree touched in the last hour is held as a possibly-live session, which
# would mask the checks below; backdate both so the other rules are what decide.
touch -t 202001010000 "$ROOT/wt-clean" "$ROOT/wt-dirty"

# 9. merged branch whose worktree is clean but freshly touched
mkbranch wt-live;                 seed i.txt I i
squash_merge wt-live
git checkout -q develop
git push -q origin wt-live 2>/dev/null || true
git worktree add -q "$ROOT/wt-live" wt-live

RESULT=$("$SCRIPT" --base develop --no-fetch --no-fetch --json 2>/dev/null)

if [ -n "${DEBUG_VERDICTS:-}" ]; then
  printf '%s' "$RESULT" | jq -r '.[] | "\(.verdict)\t\(.branch)\t\(.proof)\(.detail)"' >&2
fi

PASS=0
FAIL=0

expect_detail() {  # expect_detail <branch> <substring> <description>
  local br="$1" want="$2" desc="$3" got
  got=$(printf '%s' "$RESULT" | jq -r --arg b "$br" '.[] | select(.branch==$b) | "\(.proof)\(.detail)"')
  case "$got" in
    *"$want"*) PASS=$((PASS + 1)) ;;
    *) FAIL=$((FAIL + 1))
       printf 'FAIL  %-24s %s\n      want text: %s\n      got:       %s\n' "$br" "$desc" "$want" "$got" >&2 ;;
  esac
}

expect() {  # expect <branch> <verdict> <description>
  local br="$1" want="$2" desc="$3" got
  got=$(printf '%s' "$RESULT" | jq -r --arg b "$br" '.[] | select(.branch==$b) | .verdict')

  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL  %-24s want=%-6s got=%-6s  %s\n' "$br" "$want" "${got:-<none>}" "$desc" >&2
    printf '%s' "$RESULT" | jq -r --arg b "$br" '.[] | select(.branch==$b) | "      detail: \(.detail)"' >&2
  fi
}

expect ff-merged        DELETE "ancestor of base"
expect squash-clean     DELETE "squash-merged, content still equivalent"
expect squash-then-more KEEP   "work added after the squash merge"
expect never-merged     KEEP   "never merged"
expect base-moved       DELETE "single-commit squash keeps its patch-id, so C sees it"
expect unpushed         KEEP   "never pushed, no PR"
expect wt-clean         DELETE "merged, worktree clean and idle"
expect wt-dirty         KEEP   "worktree holds an untracked file"
expect wt-live          KEEP   "worktree touched within the hour"
expect_detail wt-live "may be a live session (otherwise DELETE: " "the 1h veto names the verdict it holds back"
expect picked           DELETE "every commit cherry-picked into the base"
expect picked-plus      KEEP   "one commit still only on the branch"
expect develop          KEEP   "base and current branch"

# --help prints the whole header, Usage included.
if "$SCRIPT" --help 2>/dev/null | grep -q '^# Usage:'; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL  --help omits the Usage section" >&2; fi

# A flag missing its value is a usage error, not an endless loop.
"$SCRIPT" --no-fetch --branch >/dev/null 2>&1 & BC=$!
( sleep 10; kill "$BC" 2>/dev/null ) & WD=$!
wait "$BC"; BC_STATUS=$?
kill "$WD" 2>/dev/null
if [ "$BC_STATUS" -eq 2 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL  --branch with no value should exit 2 (got $BC_STATUS)" >&2; fi

# --apply must refuse to act without an explicit branch list.
if "$SCRIPT" --base develop --no-fetch --apply >/dev/null 2>&1; then
  FAIL=$((FAIL + 1))
  echo "FAIL  --apply without --branch should refuse" >&2
else
  PASS=$((PASS + 1))
fi

# --apply on a vetoed branch must skip it and leave it in place.
"$SCRIPT" --base develop --no-fetch --apply --branch squash-then-more >/dev/null 2>&1
if git rev-parse --verify --quiet squash-then-more >/dev/null; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "FAIL  --apply deleted a branch that had work after the merge" >&2
fi

# --apply on a proven branch removes branch and worktree together.
"$SCRIPT" --base develop --no-fetch --apply --branch wt-clean >/dev/null 2>&1
if git rev-parse --verify --quiet wt-clean >/dev/null || [ -d "$ROOT/wt-clean" ]; then
  FAIL=$((FAIL + 1))
  echo "FAIL  --apply left a provably-contained branch or its worktree behind" >&2
else
  PASS=$((PASS + 1))
fi

# --- Proof B: a merged PR whose head contains the tip ------------------------
# The stub gh answers `pr list --head <br>` from head-<br>.json and
# `api .../commits/<sha>/pulls` from commit-<sha>.json, and logs each call.
# It answers only for origin's repository (-R / repos/ and --hostname), as
# gh resolving a fork to its upstream would not; a commit with no file is one
# GitHub never received (HTTP 422), and GH_FAIL fails like an offline or
# unauthenticated gh. Origin's URL names that repository, rewritten to the
# local bare repo by insteadOf. Each PR is squash-merged and the base then
# edits the same file, so proofs A and C both miss and only B can decide.
# PR heads are built in a second clone and published as refs/pull/<n>/head,
# so whether the head object is in this repo is up to each case.
GH_STUB="$ROOT/gh-stub"
mkdir -p "$GH_STUB/bin"
cat > "$GH_STUB/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_STUB/calls"
[ -z "${GH_FAIL:-}" ] || { echo "gh: offline" >&2; exit 1; }
f="" state=all repo="" host=""
case "$1 $2" in
  "pr list")
    while [ "$#" -gt 0 ]; do
      case "$1" in --head) f="$GH_STUB/head-$2.json" ;; --state) state="$2" ;; -R) repo="$2" ;; esac
      shift
    done
    [ "$repo" = github.example/acme/widget ] || { echo '[]'; exit 0; } ;;
  api\ *)
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --hostname) host="$2"; shift ;;
        repos/acme/widget/commits/*/pulls) sha="${1%/pulls}"; f="$GH_STUB/commit-${sha##*/}.json" ;;
      esac
      shift
    done
    [ "$host" = github.example ] && [ -n "$f" ] || { echo '[]'; exit 0; }
    [ -f "$f" ] || { echo '{"message":"No commit found for SHA"}'; echo "gh: HTTP 422" >&2; exit 1; } ;;
esac
[ -n "$f" ] && [ -f "$f" ] || { echo '[]'; exit 0; }
jq -c --arg s "$state" '[.[] | select($s == "all" or ((.state // "") | ascii_downcase) == $s)]' "$f"
STUB
chmod +x "$GH_STUB/bin/gh"
export GH_STUB
# gh_head <branch> <head sha> <STATE> <number> [base]
gh_head()   { printf '[{"state":"%s","headRefOid":"%s","number":%s,"baseRefName":"%s"}]\n' "$3" "$2" "$4" "${5:-develop}" > "$GH_STUB/head-$1.json"; }
# gh_commit <sha> <head sha> <number>: a PR merged into develop
gh_commit() { printf '[{"state":"closed","merged_at":"2026-01-01T00:00:00Z","number":%s,"head":{"sha":"%s"},"base":{"ref":"develop"}}]\n' "$3" "$2" > "$GH_STUB/commit-$1.json"; }
FORGE_URL=https://github.example/acme/widget.git
git config "url.$ROOT/origin.git.insteadOf" "$FORGE_URL"
git remote set-url origin "$FORGE_URL"

OTHER="$ROOT/other"
git checkout -q develop; git push -q origin develop
git clone -q "$ROOT/origin.git" "$OTHER"
git -C "$OTHER" config user.email t@t; git -C "$OTHER" config user.name t
oseed() { echo "$2" > "$OTHER/$1"; git -C "$OTHER" add -A; git -C "$OTHER" commit -qm "$3"; }
# other_merge <ref> <n> <file>: publish <ref> as PR <n>'s head, squash-merge it,
# then edit <file> on the base so content and patch-ids both drift.
other_merge() {
  git -C "$OTHER" push -q -f origin "$1:refs/pull/$2/head"
  git -C "$OTHER" checkout -q develop
  git -C "$OTHER" pull -q --ff-only origin develop
  git -C "$OTHER" merge -q --squash "$1" >/dev/null 2>&1
  git -C "$OTHER" commit -qm "squash (#$2)"
  oseed "$3" "$3-later" "later edit to $3"
  git -C "$OTHER" push -q origin develop
}
sync_develop() { git fetch -q --prune origin; git checkout -q develop; git merge -q --ff-only origin/develop; }

# pb-behind, pb-fetch: pushed at the local tip; a review fix was pushed to the
# PR from elsewhere, so the local tip is behind the merged head. pb-behind has
# the head object locally; pb-fetch must fetch it.
for spec in pb-behind:21 pb-fetch:22; do
  b="${spec%:*}" n="${spec#*:}"
  mkbranch "$b"; seed "$b.txt" "$b-1" "$b one"; git push -q -u origin "$b"
  git -C "$OTHER" fetch -q origin
  git -C "$OTHER" checkout -q -b "$b" "origin/$b"
  oseed "$b.txt" "$b-2" "$b review fix"
  gh_head "$b" "$(git -C "$OTHER" rev-parse HEAD)" MERGED "$n"
  other_merge "$b" "$n" "$b.txt"
  git -C "$OTHER" push -q origin --delete "$b"
done

# pr-31, pr-32: a local name apart from the PR's head branch
# (`fetch pull/N/head:pr-N`), no upstream, then the PR got one more commit.
# Only the commit lookup finds it. pr-32's name also matches an older merged
# PR that does not contain it, which must not stop the commit lookup.
for n in 31 32; do
  git -C "$OTHER" checkout -q -b "feat-$n" develop; oseed "pr$n.txt" one "pr$n one"
  git -C "$OTHER" push -q origin "HEAD:refs/pull/$n/head"
  git fetch -q origin "refs/pull/$n/head:pr-$n"
  oseed "pr$n.txt" two "pr$n two"
  gh_commit "$(git rev-parse "pr-$n")" "$(git -C "$OTHER" rev-parse HEAD)" "$n"
  other_merge "feat-$n" "$n" "pr$n.txt"
done
gh_head pr-32 "$(git rev-parse develop)" MERGED 12

# pb-extra, pr-41: the merged head is in the branch, plus one commit that never
# reached any PR. pb-extra is found by name; pr-41's tip was never pushed, so
# GitHub knows no PR for it.
mkbranch pb-extra; seed pb-extra.txt x "pb-extra"; git push -q -u origin pb-extra
gh_head pb-extra "$(git rev-parse pb-extra)" MERGED 23
git -C "$OTHER" fetch -q origin
other_merge origin/pb-extra 23 pb-extra.txt
git -C "$OTHER" push -q origin --delete pb-extra
git -C "$OTHER" checkout -q -b feat-41 develop; oseed pr41.txt one "pr41"
git -C "$OTHER" push -q origin "HEAD:refs/pull/41/head"
git fetch -q origin "refs/pull/41/head:pr-41"
gh_commit "$(git rev-parse pr-41)" "$(git rev-parse pr-41)" 41
other_merge feat-41 41 pr41.txt
sync_develop
git checkout -q pb-extra; seed pb-extra-2.txt y "never in a PR"
git checkout -q pr-41;    seed pr41-2.txt y "never in a PR"

# pb-closed: pushed, its PR closed without merging.
mkbranch pb-closed; seed pb-closed.txt z "pb-closed"; git push -q -u origin pb-closed
gh_head pb-closed "$(git rev-parse pb-closed)" CLOSED 51
# pb-stack: its PR merged into feature-a, whose own PR never merged, so none
# of it reached develop.
mkbranch pb-stack; seed pb-stack.txt s "pb-stack"; git push -q -u origin pb-stack
gh_head pb-stack "$(git rev-parse pb-stack)" MERGED 61 feature-a
git checkout -q develop
git fetch -q origin refs/pull/21/head

PB="--branch pb-behind --branch pb-fetch --branch pr-31 --branch pr-32 --branch pb-extra --branch pr-41 --branch pb-closed --branch pb-stack"
# shellcheck disable=SC2086 # PB is a word list
RESULT=$(PATH="$GH_STUB/bin:$PATH" "$SCRIPT" --base develop --no-fetch --json $PB 2>/dev/null)
expect        pb-behind DELETE "tip behind the merged PR head, head present"
expect_detail pb-behind "tip contained in merged PR #21 head" "proof names the PR"
expect        pb-fetch  KEEP   "--no-fetch: head object absent, so no proof"
expect_detail pb-fetch  "is not available locally" "says the head is missing, not that work was added"
expect        pr-31     KEEP   "--no-fetch: renamed branch, head object absent"
expect        pb-extra  KEEP   "a commit after the merged head"
expect_detail pb-extra  "work added after the merge" "names the unmerged work"
expect        pr-41     KEEP   "renamed branch whose tip GitHub never received"
expect_detail pr-41     "local-only work" "an unknown commit finds no PR"
expect        pb-closed KEEP   "PR closed unmerged"
expect_detail pb-closed "PR #51 closed unmerged" "names the closed PR"
expect        pb-stack  KEEP   "PR merged into a branch that never reached the base"
expect_detail pb-stack  "PR #61 merged into feature-a, not develop" "names where it merged"

# shellcheck disable=SC2086 # PB is a word list
RESULT=$(PATH="$GH_STUB/bin:$PATH" "$SCRIPT" --base develop --json $PB 2>/dev/null)
expect        pb-fetch  DELETE "head fetched from refs/pull/22/head"
expect        pr-31     DELETE "renamed branch found by commit, head fetched"
expect_detail pr-31     "tip contained in merged PR #31 head" "proof names the PR"
expect        pr-32     DELETE "a name match that proves nothing falls through to the commit lookup"
expect_detail pr-32     "tip contained in merged PR #32 head" "proof names the commit's PR"
expect        pb-extra  KEEP   "still KEEP when fetching is allowed"
expect        pr-41     KEEP   "still KEEP when fetching is allowed"

RESULT=$(GH_FAIL=1 PATH="$GH_STUB/bin:$PATH" "$SCRIPT" --base develop --no-fetch --json --branch pr-31 2>/dev/null)
expect        pr-31     KEEP   "gh failing (offline, unauthenticated) fails open to KEEP"

# --apply classifies twice (audit, then re-verify); gh is asked once per key.
: > "$GH_STUB/calls"
PATH="$GH_STUB/bin:$PATH" "$SCRIPT" --base develop --no-fetch --apply --branch pr-32 >/dev/null 2>&1
if git rev-parse --verify --quiet pr-32 >/dev/null; then
  FAIL=$((FAIL + 1)); echo "FAIL  --apply kept pr-32, proven by its commit's PR" >&2
elif [ "$(grep -c '' "$GH_STUB/calls")" -eq 2 ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); printf 'FAIL  --apply repeated gh calls:\n%s\n' "$(cat "$GH_STUB/calls")" >&2
fi

git remote set-url origin "$ROOT/origin.git"
git config --unset "url.$ROOT/origin.git.insteadOf"

# --- --unattended: the vetoes for a caller that removes without asking ------
# Five merged, pushed branches, each with a clean worktree idle past the 1h
# veto; one condition each that only --unattended honours.
old_admin() {  # back-date the worktree and git's record of activity in it
  local admin
  admin=$(git -C "$1" rev-parse --absolute-git-dir)
  touch -t 202001010000 "$1" "$admin/HEAD" "$admin/logs/HEAD"
}
printf '*.local\nnode_modules/\n__pycache__/\n.idea/\n.env\nout/\n' > .gitignore; git add .gitignore; git commit -qm ignore; git push -q origin develop
for b in uw-git uw-session uw-proc uw-ignored uw-idle uw-deps uw-nested uw-outenv uw-link; do
  mkbranch "$b"; seed "$b.txt" "$b" "$b"
  squash_merge "$b"
  git push -q origin "$b"
  git worktree add -q "$ROOT/$b" "$b"
  touch -t 202001010000 "$ROOT/$b"
done
git checkout -q develop
for b in uw-session uw-proc uw-ignored uw-idle uw-deps uw-nested uw-outenv uw-link; do old_admin "$ROOT/$b"; done
mkdir -p .claude/state/sessions
jq -cn --arg r "$ROOT/uw-session" --argjson at "$(date +%s)" \
  '{t:"write",root:$r,rel:"x.txt",kind:"code",via:"tool",at:$at}' > .claude/state/sessions/s1.jsonl
(cd "$ROOT/uw-proc/" && exec sleep 300) & PROC=$!
echo secret > "$ROOT/uw-ignored/dev.local"; touch -t 202001010000 "$ROOT/uw-ignored"
# Dependencies and caches are rebuilt by an install: they do not hold it.
mkdir -p "$ROOT/uw-deps/node_modules/pkg" "$ROOT/uw-deps/src/__pycache__"
touch "$ROOT/uw-deps/node_modules/pkg/index.js" "$ROOT/uw-deps/src/__pycache__/m.pyc"
mkdir -p "$ROOT/uw-deps/.idea"; touch "$ROOT/uw-deps/.idea/workspace.xml"
touch -t 202001010000 "$ROOT/uw-deps"
# A secret under a directory named like build output is still a secret.
mkdir -p "$ROOT/uw-nested/docker/build"; echo s > "$ROOT/uw-nested/docker/build/.env"
touch -t 202001010000 "$ROOT/uw-nested"
# A secret put directly in an ignored output directory.
mkdir -p "$ROOT/uw-outenv/out"; echo s > "$ROOT/uw-outenv/out/.env"
touch -t 202001010000 "$ROOT/uw-outenv"
# An isolation decision recorded through a symlink to the worktree.
ln -s "$ROOT/uw-link" "$ROOT/uw-link-alias"
jq -cn --arg p "$ROOT/uw-link-alias" --argjson at "$(date +%s)" \
  '{t:"isolation",mode:"worktree",path:$p,at:$at}' > .claude/state/sessions/s2.jsonl
sleep 1

RESULT=$("$SCRIPT" --base develop --no-fetch --json --unattended 2>/dev/null)
expect uw-git     KEEP   "--unattended: git activity in the worktree in the last 24h"
expect_detail uw-git "may be in use: git activity in the last 24h (otherwise DELETE: " "the unattended veto names the verdict it holds back"
expect uw-session KEEP   "--unattended: a session wrote in the worktree in the last 24h"
expect uw-proc    KEEP   "--unattended: a process runs inside the worktree"
expect uw-ignored KEEP   "--unattended: the worktree holds an ignored file"
expect uw-idle    DELETE "--unattended: none of the above"
expect uw-deps    DELETE "--unattended: only regenerable ignored files (node_modules, __pycache__, .idea)"
expect uw-nested  KEEP   "--unattended: docker/build/.env is not build output"
expect uw-outenv  KEEP   "--unattended: a .env directly inside ignored out/"
expect uw-link    KEEP   "--unattended: an isolation path recorded through a symlink"
kill "$PROC" 2>/dev/null; wait "$PROC" 2>/dev/null

RESULT=$("$SCRIPT" --base develop --no-fetch --json 2>/dev/null)
expect uw-git     DELETE "without --unattended the 24h vetoes do not apply"
expect uw-ignored DELETE "without --unattended an ignored file does not hold it"

# --- #378: empty arrays under bash < 4.4 ---------------------------------------
# --json with no row to print, under every bash at hand (lib/tests/old-bash.sh).
old_bash_dirs "$ROOT"
# No local branch at all: a detached HEAD with the base a tag.
E378="$ROOT/no-branches-378"
git init -q -b main "$E378"
git -C "$E378" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$E378" tag v1; git -C "$E378" checkout -q --detach; git -C "$E378" branch -q -D main
for dir in "${TEST_BASH_DIRS[@]}"; do
  on="${dir:+ under /bin/bash}"
  OUT=$(PATH="${dir:+$dir:}$PATH" "$SCRIPT" --base develop --no-fetch --json --unattended --branch nope 2>"$ROOT/err-378" | jq -c . 2>/dev/null)
  if [ "$OUT" = "[]" ] && ! grep -q 'unbound variable' "$ROOT/err-378"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL  --json with every named branch missing prints []$on (got: $OUT; $(cat "$ROOT/err-378"))" >&2; fi
  OUT=$(cd "$E378" && PATH="${dir:+$dir:}$PATH" "$SCRIPT" --base v1 --no-fetch --json 2>"$ROOT/err-378" | jq -c . 2>/dev/null)
  if [ "$OUT" = "[]" ] && ! grep -q 'unbound variable' "$ROOT/err-378"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL  --json with no local branch prints []$on (got: $OUT; $(cat "$ROOT/err-378"))" >&2; fi
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
