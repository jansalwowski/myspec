#!/usr/bin/env bash
# Tests for lib/bash-write-targets.sh: tilde paths (#451).
#
# An unquoted leading `~` or `~/` is $HOME, as bash expands it, so
# `rm ~/x/CLAUDE.md` run from a repository names a file outside it, not
# `<repo>/~/x/CLAUDE.md`. `~user/...` names another home this hook does not
# look up: it names nothing, like a variable path. A quoted `'~/x'` is a
# literal relative path in bash and stays one.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/command-scan.sh
. "$HERE/../command-scan.sh"
# shellcheck source=lib/hook-core.sh
. "$HERE/../hook-core.sh"
# shellcheck source=lib/bash-write-targets.sh
. "$HERE/../bash-write-targets.sh"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }
eq()   { if [ "$1" = "$2" ]; then ok; else fail "$3 (want '$2', got '$1')"; fi; }

# `pwd -P`: on macOS $TMPDIR is under /var, a symlink to /private/var.
FX=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/bwt.XXXXXX")
trap 'rm -rf "$FX"' EXIT
REPO="$FX/repo"
# Never the real home: the cases list and glob files under it.
export HOME="$FX/home"
mkdir -p "$REPO" "$HOME/d"
: > "$HOME/d/g.md"
: > "$REPO/a.txt"
# A file whose name starts with ~ is a name, not a home.
: > "$REPO/~bak"

targets() {  # targets <command>: bash_write_targets for it from $REPO
  ( COMMAND=$1 BASE_DIR=$REPO; SCAN_PLAIN="" SCAN_KEEP="" SCAN_KEPT=0
    scan_command keep; bash_write_targets )
}

eq "$(targets 'rm ~/d/CLAUDE.md')" "$HOME/d/CLAUDE.md" "rm ~/x is under \$HOME"
eq "$(targets 'rm ~/nowhere/CLAUDE.md')" "$HOME/nowhere/CLAUDE.md" "rm ~/x under a missing directory"
eq "$(targets 'echo x > ~/d/a.txt')" "$HOME/d/a.txt" "redirect to ~/x"
eq "$(targets 'echo x >~/d/b.txt')" "$HOME/d/b.txt" "attached redirect to ~/x"
eq "$(targets 'echo x>~/d/c.txt')" "$HOME/d/c.txt" "redirect attached mid-word to ~/x"
eq "$(targets 'cp a.txt ~/d')" "$HOME/d/a.txt" "cp into ~/dir"
eq "$(targets 'cp a.txt ~')" "$HOME/a.txt" "cp into bare ~"
eq "$(targets 'mv ~/d/m.txt ~/d/n.txt')" "$HOME/d/m.txt
$HOME/d/n.txt" "mv between ~ paths"
eq "$(targets 'rm ~/d/*.md')" "$HOME/d/g.md" "glob under ~"
eq "$(targets 'rm ~root/x.txt')" "" "~user/x names nothing"
eq "$(targets 'echo x > ~root/x.txt')" "" "redirect to ~user/x names nothing"
eq "$(targets 'cp a.txt ~root/x.txt')" "" "cp to ~user/x names nothing"
eq "$(targets "rm '~/d/q.txt'")" "$REPO/~/d/q.txt" "single-quoted ~/x stays relative"
eq "$(targets 'rm "~/d/q.txt"')" "$REPO/~/d/q.txt" "double-quoted ~/x stays relative"
eq "$(targets 'rm "~"/d/q.txt')" "$REPO/~/d/q.txt" "quoted ~ then /x stays relative"
eq "$(targets 'rm ~"/d/q.txt"')" "$REPO/~/d/q.txt" "~ then quoted /x stays relative"
eq "$(targets 'rm ~/"d/q.txt"')" "$HOME/d/q.txt" "tilde-slash then a quoted rest is under HOME"
eq "$(targets "echo x > '~/d/r.txt'")" "$REPO/~/d/r.txt" "redirect to quoted ~/x stays relative"
eq "$(targets 'rm x~/y.txt')" "$REPO/x~/y.txt" "a ~ inside a word is literal"
# Sorted: compgen's order follows the locale's collation.
eq "$(targets 'rm *' | LC_ALL=C sort)" "$REPO/a.txt
$REPO/~bak" "a glob match named ~bak is a file in the directory"
eq "$(targets 'ln -s /opt/~cfg')" "$REPO/~cfg" "one-operand ln links ~cfg into the directory"
eq "$(targets 'rm ~+/b.txt')" "$REPO/b.txt" "~+ is the current directory"
eq "$(targets 'cp a.txt ~+')" "$REPO/a.txt" "cp into bare ~+"
eq "$(targets 'rm ~-/b.txt')" "" "~- (OLDPWD) names nothing, like a variable"
eq "$(targets 'dd if=a.txt of=~/d/x')" "$HOME/d/x" "dd of=~/x is under \$HOME"
eq "$(targets "dd if=a.txt of='~/d/x'")" "$REPO/~/d/x" "dd of= a quoted ~/x stays relative"
eq "$(targets 'dd if=a.txt of="~"/d/x')" "$REPO/~/d/x" "dd of= a quoted ~ then /x stays relative"
# A home whose name holds glob characters is matched as a name, as bash
# does: h[1] must not match the sibling h1.
GH="$FX/g[1]"
mkdir -p "$GH" "$FX/g1"
: > "$GH/a.md"
: > "$FX/g1/s.md"
eq "$(HOME=$GH targets 'rm ~/*.md')" "$GH/a.md" "a glob under ~ stays inside a home with glob characters"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
