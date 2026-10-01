#!/usr/bin/env bash
# Regression fixture for .githooks/pre-commit and scripts/install-git-hooks.sh.
#
# Everything runs in a throwaway clone. The installer writes git config, and a
# worktree shares .git/config with the main checkout, so it must never run
# against the repo this suite lives in. The git environment a calling hook may
# export (GIT_DIR, GIT_INDEX_FILE, ...) is cleared for the same reason.
#
# Usage: git-hooks.test.sh

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=$(cd "$HERE/../.." && pwd)
for f in scripts/lint-skills.mjs scripts/lint-sh.sh scripts/install-git-hooks.sh .githooks/pre-commit; do
  [ -f "$SRC/$f" ] || { echo "FATAL: missing $SRC/$f" >&2; exit 1; }
done

# shellcheck disable=SC2046
unset $(git rev-parse --local-env-vars 2>/dev/null)
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

TMP=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }
expect_line()    { if grep -Eq -- "$1" <<<"$OUTPUT"; then ok; else fail "$2 (no line matching: $1)"; fi; }
expect_no_line() { if grep -Eq -- "$1" <<<"$OUTPUT"; then fail "$2 (unexpected line matching: $1)"; else ok; fi; }
expect_exit()    { if [ "$STATUS" -eq "$1" ]; then ok; else fail "$2 (exit $STATUS, want $1)"; fi; }
in_repo() { OUTPUT=$(cd "${WT:-$REPO}" && "$@" 2>&1); STATUS=$?; [ -z "${DEBUG:-}" ] || printf "%s\n" "$OUTPUT" >&2; }
hooks_path() { git -C "$REPO" config --local --get core.hooksPath; }

good_skill() {
  mkdir -p "$(dirname "$1")"
  printf -- '---\nname: %s\ndescription: "Use when a demo needs linting. Do NOT use for real work."\n---\n\n# Demo\n' "$2" > "$1"
}
bad_skill() {
  mkdir -p "$(dirname "$1")"
  printf -- '---\nname: %s\ndescription: "Use to lint demos."\n---\n\n# Demo\n' "$2" > "$1"
}

mkdir -p "$REPO/scripts" "$REPO/.githooks" "$REPO/skills" "$REPO/hooks"
cp "$SRC/scripts/lint-skills.mjs" "$SRC/scripts/lint-sh.sh" "$SRC/scripts/install-git-hooks.sh" "$REPO/scripts/"
cp "$SRC/.githooks/pre-commit" "$REPO/.githooks/"
cd "$REPO" || exit 1
git init -q -b main .
git config user.email t@t
git config user.name t
good_skill skills/base/SKILL.md base
git add -A
git commit -qm init

# ── installer ───────────────────────────────────────────────────────────────
in_repo scripts/install-git-hooks.sh
expect_exit 0 "install exits 0"
expect_line "set core.hooksPath=\.githooks" "install says what it set"
expect_line "active: \.githooks/pre-commit" "install lists the active hook"
[ "$(hooks_path)" = ".githooks" ] && ok || fail "install writes core.hooksPath=.githooks"

in_repo scripts/install-git-hooks.sh
expect_exit 0 "second install exits 0"
expect_line "already \.githooks; nothing to do" "install is idempotent"

git worktree add -q "$TMP/wt" -b wt-branch
WT="$TMP/wt" in_repo scripts/install-git-hooks.sh
expect_line "already \.githooks" "install from a linked worktree sees the shared setting"
WT="$TMP/wt" in_repo git rev-parse --git-path hooks
expect_line "^\.githooks$" "a linked worktree resolves hooks to its own .githooks"

git config --local core.hooksPath .husky
in_repo scripts/install-git-hooks.sh
expect_exit 1 "install refuses to replace a foreign hooksPath"
[ "$(hooks_path)" = ".husky" ] && ok || fail "a refused install leaves the foreign hooksPath"
in_repo scripts/install-git-hooks.sh --uninstall
expect_line "is \.husky, not \.githooks; left unchanged" "uninstall leaves a foreign hooksPath"
in_repo scripts/install-git-hooks.sh --force
expect_line "replaced \.husky" "--force replaces and says what it replaced"
in_repo scripts/install-git-hooks.sh --uninstall
expect_line "restored core.hooksPath=\.husky" "uninstall after --force says it restored the replaced value"
[ "$(hooks_path)" = ".husky" ] && ok || fail "uninstall after --force restores the replaced hooksPath"
git config --local --get myspec.previousHooksPath >/dev/null && fail "the restore clears its record" || ok

# The default hooks dir, absolute or relative, is not a custom setup: no --force needed.
for v in "$REPO/.git/hooks" ".git/hooks"; do
  git config --local core.hooksPath "$v"
  in_repo scripts/install-git-hooks.sh
  expect_exit 0 "install replaces hooksPath=$v (the default dir) without --force"
  [ "$(hooks_path)" = ".githooks" ] && ok || fail "install over hooksPath=$v sets .githooks"
  in_repo scripts/install-git-hooks.sh --uninstall
  [ "$(hooks_path)" = "$v" ] && ok || fail "uninstall restores hooksPath=$v"
done
mkdir -p "$TMP/other/.git/hooks"
git config --local core.hooksPath "$TMP/other/.git/hooks"
in_repo scripts/install-git-hooks.sh
expect_exit 1 "another repo's .git/hooks is a custom path and still needs --force"

# A live hook in .git/hooks silently stops running once hooksPath moves: say so.
git config --local --unset core.hooksPath
printf '#!/bin/sh\nexit 0\n' > .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
in_repo scripts/install-git-hooks.sh
expect_line "warning: these hooks in .* no longer run" "install warns about hooks it disables"
expect_line "^    pre-commit$" "the disabled hook is named"
expect_no_line "\.sample" "sample hooks are not reported"
rm .git/hooks/pre-commit
in_repo scripts/install-git-hooks.sh --uninstall
expect_line "unset core.hooksPath" "uninstall with nothing recorded unsets"

printf '[core]\n\thooksPath = /elsewhere\n' > "$TMP/global.cfg"
OUTPUT=$(cd "$REPO" && GIT_CONFIG_GLOBAL="$TMP/global.cfg" scripts/install-git-hooks.sh 2>&1); STATUS=$?
expect_exit 0 "install over a global hooksPath exits 0"
expect_line "overrides your global core.hooksPath \(/elsewhere\)" "install notes the global it overrides"

in_repo scripts/install-git-hooks.sh --uninstall
expect_line "unset core.hooksPath" "uninstall unsets"
hooks_path >/dev/null && fail "uninstall removes core.hooksPath" || ok
in_repo scripts/install-git-hooks.sh --uninstall
expect_exit 0 "second uninstall exits 0"
expect_line "nothing to uninstall" "uninstall is idempotent"

in_repo scripts/install-git-hooks.sh --bogus
expect_exit 2 "an unknown flag exits 2"

in_repo scripts/install-git-hooks.sh
git worktree remove --force "$TMP/wt"

# ── pre-commit ──────────────────────────────────────────────────────────────
echo notes > README.txt
git add README.txt
in_repo git commit -qm "no skills staged"
expect_exit 0 "a commit with no skill or hook staged passes"

bad_skill skills/bad/SKILL.md bad
git add skills/bad/SKILL.md
in_repo git commit -qm "bad skill"
expect_exit 1 "a bad staged skill blocks the commit"
expect_line "skills/bad/SKILL\.md:3: DESC-USE-WHEN" "the finding is shown"
expect_line "git commit --no-verify" "the escape hatch is named"
in_repo git commit -q --no-verify -m "bypass"
expect_exit 0 "--no-verify bypasses the hook"

good_skill "skills/with space/SKILL.md" "x"
git add "skills/with space/SKILL.md"
in_repo git commit -qm "spaced path"
expect_exit 1 "a staged skill under a path with spaces is linted"
expect_line "skills/with space/SKILL\.md:2: NAME-MISMATCH" "the spaced path is reported intact"
git reset -q
rm -rf "skills/with space"

good_skill skills/fine/SKILL.md fine
git add skills/fine/SKILL.md
in_repo git commit -qm "good skill"
expect_exit 0 "a good staged skill passes"
expect_no_line "DESC-USE-WHEN" "a committed bad skill that is not staged is not linted"

git rm -q skills/fine/SKILL.md
in_repo git commit -qm "delete a skill"
expect_exit 0 "a staged deletion passes"

# The staged blob is what gets committed, so that is what is linted.
bad_skill skills/gone/SKILL.md gone
git add skills/gone/SKILL.md
rm skills/gone/SKILL.md
in_repo git commit -qm "staged then removed from disk"
expect_exit 1 "a bad staged file missing from the working tree still blocks"
expect_line "skills/gone/SKILL\.md:3: DESC-USE-WHEN" "the staged blob of a removed file is linted"
git rm -q --cached skills/gone/SKILL.md

good_skill skills/sneaky/SKILL.md other-name
git add skills/sneaky/SKILL.md
good_skill skills/sneaky/SKILL.md sneaky
in_repo git commit -qm "bad staged, clean on disk"
expect_exit 1 "a bad staged blob is blocked even when the disk copy is clean"
expect_line "skills/sneaky/SKILL\.md:2: NAME-MISMATCH" "the staged name is the one checked"
git add skills/sneaky/SKILL.md
bad_skill skills/sneaky/SKILL.md sneaky
in_repo git commit -qm "clean staged, bad on disk"
expect_exit 0 "a clean staged blob passes even when the disk copy is bad"
git checkout -q -- skills/sneaky/SKILL.md

bad_skill skills/partial/SKILL.md partial
git add skills/partial/SKILL.md && git commit -q --no-verify -m "seed partial"
good_skill skills/partial/SKILL.md partial
in_repo git commit -qm "fix via -a" -a
expect_exit 0 "commit -a lints the index git builds for it (fixed file passes)"
bad_skill skills/partial/SKILL.md partial
in_repo git commit -qm "break via path" skills/partial/SKILL.md
expect_exit 1 "commit <path> lints the temporary index for that path"
git checkout -q -- skills/partial/SKILL.md

# A link to a file only in the working tree is dead in the commit.
good_skill skills/linker/SKILL.md linker
printf '\n[ref](references/local.md)\n' >> skills/linker/SKILL.md
mkdir -p skills/linker/references && echo x > skills/linker/references/local.md
git add skills/linker/SKILL.md
in_repo git commit -qm "link to an untracked file"
expect_exit 1 "a link to an unstaged file is dead in the committed tree"
expect_line "LINK-DEAD .*references/local\.md" "the unstaged link target is reported"
git add skills/linker/references/local.md
in_repo git commit -qm "link with its target"
expect_exit 0 "staging the link target clears it"

mkdir -p plugins/myspec/skills/bad2
bad_skill plugins/myspec/skills/bad2/SKILL.md bad2
git add plugins/myspec/skills/bad2/SKILL.md
in_repo git commit -qm "bad mirror skill"
expect_exit 1 "a bad skill in the plugin mirror blocks the commit"
git reset -q
rm -rf plugins

mkdir -p skills/nested/references
bad_skill skills/nested/references/SKILL.md whatever
git add skills/nested/references/SKILL.md
in_repo git commit -qm "not a skill entry point"
expect_exit 0 "a SKILL.md deeper than skills/<name>/ is not treated as a skill"

# ShellCheck (#209). A stub stands in for shellcheck through $SHELLCHECK, so no
# case depends on which version (if any) the machine has: it flags any file
# containing SC_BAD, printing the path it was given, and exits 1; a file
# containing SC_UNREADABLE makes it exit 2 the way an unopenable file does.
mkdir -p "$TMP/scbin"
cat > "$TMP/scbin/shellcheck" <<'STUB'
#!/bin/sh
[ "$1" = --version ] && { printf 'ShellCheck stub\nversion: 0.0.0\n'; exit 0; }
rc=0
for f in "$@"; do
  if grep -q SC_BAD "$f"; then echo "In $f line 2: SC_BAD is unused"; [ "$rc" -gt 1 ] || rc=1; fi
  if grep -q SC_UNREADABLE "$f"; then echo "$f: openBinaryFile: does not exist" >&2; rc=2; fi
done
exit $rc
STUB
chmod +x "$TMP/scbin/shellcheck"
export SHELLCHECK="$TMP/scbin/shellcheck"

# 4334ff1: an apostrophe inside $(cat <<EOF ...) breaks the parse.
printf '#!/usr/bin/env bash\nmsg=$(cat <<EOF\nit'"'"'s broken\nEOF\n' > hooks/broken.sh
git add hooks/broken.sh
in_repo git commit -qm "broken hook"
expect_exit 1 "a hook script that fails bash -n blocks the commit"
expect_line "bash -n failed on hooks/broken\.sh" "the broken hook is named"
printf '#!/usr/bin/env bash\necho fine\n' > hooks/broken.sh
git add hooks/broken.sh
in_repo git commit -qm "fixed hook"
expect_exit 0 "a hook script that parses passes"

mkdir -p lib
printf '#!/usr/bin/env bash\nSC_BAD=1\n' > lib/lintme.sh
git add lib/lintme.sh
in_repo git commit -qm "shellcheck finding in lib"
expect_exit 1 "a staged lib shell script with a shellcheck finding blocks the commit"
expect_line "^In lib/lintme\.sh line 2" "the shellcheck finding is shown with a repo-relative path"
printf '#!/usr/bin/env bash\necho fine\n' > lib/lintme.sh
git add lib/lintme.sh
in_repo git commit -qm "clean lib script"
expect_exit 0 "a clean staged lib shell script passes"

printf '#!/usr/bin/env bash\nSC_BAD=1\n' > lib/lintme.sh
printf '#!/usr/bin/env bash\n# SC_UNREADABLE\n' > lib/gone.sh
git add lib/lintme.sh lib/gone.sh
in_repo git commit -qm "shellcheck exits 2"
expect_exit 1 "a shellcheck exit of 2 blocks the commit instead of skipping the lint"
expect_line "^In lib/lintme\.sh line 2" "findings printed alongside an exit of 2 are shown"
git rm -q --cached lib/gone.sh; rm lib/gone.sh

mkdir -p plugins/myspec/lib
cp lib/lintme.sh plugins/myspec/lib/lintme.sh
git add lib/lintme.sh plugins/myspec/lib/lintme.sh
in_repo git commit -qm "finding in a script and its mirror"
expect_exit 1 "a finding in a script staged with its mirror blocks the commit"
[ "$(grep -c 'SC_BAD is unused' <<<"$OUTPUT")" -eq 1 ] && ok || fail "the mirror is not linted a second time"

SHELLCHECK="$TMP/no-such-shellcheck" in_repo git commit -qm "no shellcheck installed"
expect_exit 0 "without shellcheck the commit goes through"
expect_line "shellcheck not found; shell lint skipped" "the skip is announced"
printf '#!/usr/bin/env bash\necho fine\n' > lib/lintme.sh
cp lib/lintme.sh plugins/myspec/lib/lintme.sh
git add lib/lintme.sh plugins/myspec/lib/lintme.sh
in_repo git commit -qm "clean again"
expect_exit 0 "the cleaned script and mirror pass"

# JS lint (#208). A stub stands in for scripts/lint-js.sh so the suite stays
# offline: it flags any file containing unusedVar the way eslint does (absolute
# path, exit 1), and fails its --version probe when STUB_ESLINT_DOWN is set.
# A fake npx on PATH satisfies the hook's npx check without a node install.
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/npx"
chmod +x "$TMP/bin/npx"
cat > scripts/lint-js.sh <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  [ -z "${STUB_ESLINT_DOWN:-}" ] || exit 127
  echo v0; exit 0
fi
rc=0
for f in "$@"; do
  if grep -q unusedVar "$f"; then
    printf '%s\n  1:7  error  unusedVar is defined but never used  no-unused-vars\n' "$(pwd -P)/$f"
    rc=1
  fi
done
exit $rc
STUB
git add scripts/lint-js.sh && git commit -q --no-verify -m "stub js lint"
mkdir -p lib plugins/myspec/lib
echo 'const unusedVar = 1' > lib/bad.mjs
git add lib/bad.mjs
PATH="$TMP/bin:$PATH" in_repo git commit -qm "bad lib js"
expect_exit 1 "a staged lib JS file with an eslint finding blocks the commit"
expect_line "^lib/bad\.mjs$" "the finding is shown with a repo-relative path"
STUB_ESLINT_DOWN=1 PATH="$TMP/bin:$PATH" in_repo git commit -qm "eslint unavailable"
expect_exit 0 "when eslint cannot run, the commit is not blocked"
expect_line "eslint could not run .*JS lint skipped" "the skip is announced"
git reset -q
echo 'export const used = 1' > plugins/myspec/lib/ok.mjs
git add plugins/myspec/lib/ok.mjs
PATH="$TMP/bin:$PATH" in_repo git commit -qm "clean mirror js"
expect_exit 0 "a clean staged mirror lib JS file passes"
expect_no_line "lib/bad\.mjs" "an unstaged lib JS file is not linted"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
