#!/usr/bin/env bash
# Tests for lib/command-scan.sh: the keep-mode encoding and its decoding.
# decode_word must give back every character sanitize_command keep encoded,
# under every bash the hooks run in: macOS ships 3.2, Linux CI and most
# hosts 5.x, where patsub_replacement (on by default since 5.2) makes an
# unquoted `&` in a ${var//pat/rep} replacement mean the matched text. A
# decoder that missed `&` left `&&` encoded, and guard-worktree-context.sh
# never saw the command after it (`sh -lc 'cd . && git rebase develop'`).

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/command-scan.sh
. "$HERE/../command-scan.sh"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }
eq()   { if [ "$1" = "$2" ]; then ok; else fail "$3 (want '$2', got '$1')"; fi; }

# Each encoded byte decodes to its character, alone and between letters.
check_byte() {  # check_byte <encoded byte> <character> <name>
  local out
  # The trailing x keeps a decoded newline from $( )'s trimming.
  eq "$(decode_word "$1"; printf x)" "$2x" "decode_word: $3"
  eq "$(decode_word "a$1b")" "a$2b" "decode_word: $3 inside a word"
  decode_word_to out "x$1$1y"
  eq "$out" "x$2$2y" "decode_word_to: $3 twice"
}
check_byte $'\037' ' ' "space"
check_byte $'\036' $'\n' "newline"
check_byte $'\021' '|' "pipe"
check_byte $'\022' '&' "ampersand"
check_byte $'\023' ';' "semicolon"
check_byte $'\024' '(' "open paren"
check_byte $'\025' ')' "close paren"
check_byte $'\026' '{' "open brace"
check_byte $'\027' '}' "close brace"
check_byte $'\030' '`' "backtick"
eq "$(decode_word $'\035'"quoted")" "quoted" "decode_word: the span marker is dropped"
eq "$(decode_word 'a\b&c')" 'a\b&c' "decode_word: a plain backslash and & pass through"

# Round trip: the quoted payload of a command, through the keep scan and
# back, is the text that was quoted.
roundtrip() {  # roundtrip <payload> <desc>
  local line word
  line=$(printf "sh -lc '%s'" "$1" | sanitize_command keep | split_segments | head -1)
  word=${line#*$'\t'}
  word=${word#sh -lc }
  eq "$(decode_word "$word")" "$1" "round trip: $2"
}
roundtrip 'cd . && git rebase develop' "&&"
roundtrip 'a || b; c | d & e' "|| ; | &"
# shellcheck disable=SC2016 # a literal backtick is the point
roundtrip '(cd x) { y; } `z`' "( ) { } backtick"
roundtrip $'one\ntwo  three' "newline and spaces"

# `>|` is a clobber redirect: its target stays in the segment (#348 review).
eq "$(printf '%s' 'echo x >| out.ts' | sanitize_command | split_segments | awk -F'\t' '$2 != ""')" $'^\techo x > out.ts' "split: >| keeps its target"
eq "$(printf '%s' 'ls | wc' | sanitize_command | split_segments | awk -F'\t' '$2 != ""' | wc -l | tr -d ' ')" "2" "split: a plain pipe still splits"

# Quoting nests through $( ), ${ } and backticks inside a double-quoted
# word (#382): the inner quotes pair up, so the word stays one span and a `>`
# in the inner string is not a redirect. A heredoc, comment or single quote
# inside the substitution cannot end the outer word either.
plain() { printf '%s' "$1" | sanitize_command | split_segments | awk -F'\t' '$2 != ""'; }
# shellcheck disable=SC2016 # literal $( ) and backticks are the point
{
eq "$(plain 'x="$(echo "a > b")"')" $'^\tx=Q' "nest: quotes inside \$( ) in a double-quoted word"
eq "$(plain 'until [ "$(psql db -Atc "select 1 where t > now()")" = "0" ]; do sleep 5; done')" $'^\tuntil [ Q = Q ]\n|\t do sleep 5\n|\t done' "nest: the polling loop of #382"
eq "$(plain 'x="$(a "$(b "$(c "d > e")")")"')" $'^\tx=Q' "nest: three levels deep"
eq "$(plain 'x="`echo "a > b"`"')" $'^\tx=Q' "nest: quotes inside backticks in a double-quoted word"
eq "$(plain 'x="${y:-"a > b"}"')" $'^\tx=Q' "nest: quotes inside \${ } in a double-quoted word"
eq "$(plain 'x="$(( (1) > 0 ))" > o')" $'^\tx=Q > o' "nest: \$(( )) with inner parens"
eq "$(plain $'m="$(cat <<\'EOF\'\nit\'s "x" ) > y\nEOF\n)" > o')" $'^\tm=Q > o' "nest: a heredoc body inside \$( ) in quotes"
eq "$(plain $'m="$(echo hi # it\'s\n)" > o')" $'^\tm=Q > o' "nest: a comment inside \$( ) in quotes"
eq "$(plain 'echo "$(cat a)" > out.txt')" $'^\techo Q > out.txt' "nest: a redirect after the word is still seen"
eq "$(plain 'echo $(cat a > b) "c"')" $'^\techo $\n(\tcat a > b\n)\t Q' "nest: an unquoted \$( ) is still split open"
}

# The keep scan splits into the same segments and words as the plain one.
aligned() {  # aligned <command> <desc>
  local p k
  p=$(printf '%s' "$1" | sanitize_command | split_segments | awk -F'\t' '{ m = (NF > 1) ? split($2, w, /[ \t]+/) : 0; print $1, m }')
  k=$(printf '%s' "$1" | sanitize_command keep | split_segments | awk -F'\t' '{ m = (NF > 1) ? split($2, w, /[ \t]+/) : 0; print $1, m }')
  eq "$k" "$p" "aligned: $2"
}
# shellcheck disable=SC2016 # literal $( ) and backticks are the point
{
aligned 'x="$(echo "a > b; c && d")" y z' "nested quotes with separators"
aligned 'x="$(a "$(b "c | d")")" && cd "e f" && echo "`g "h i"`" > o' "deep nesting and a backtick"
aligned $'git commit -m "$(cat <<\'EOF\'\nsubject (x) && y\n\nbody; it\'s\nEOF\n)" && echo ok > o' "a heredoc commit message"
}
# shellcheck disable=SC2016 # literal $( ) is the point
{
line=$(printf '%s' 'cd "$(echo "a b")"' | sanitize_command keep | split_segments | head -1)
word=${line#*$'\t'}
eq "$(decode_word "${word#cd }")" '$(echo "a b")' "keep: a nested word decodes to its text"
}

# bash_write_targets over the scans: the targets of a nested-quote command.
# shellcheck source=lib/hook-core.sh
. "$HERE/../hook-core.sh"
# shellcheck source=lib/bash-write-targets.sh
. "$HERE/../bash-write-targets.sh"
FX=$(mktemp -d)
FX=$(cd "$FX" && pwd -P)
targets() {  # targets <command>: bash_write_targets for it from $FX
  ( COMMAND=$1 BASE_DIR=$FX; SCAN_PLAIN="" SCAN_KEEP="" SCAN_KEPT=0
    scan_command keep; bash_write_targets )
}
# shellcheck disable=SC2016 # literal $( ) is the point
{
eq "$(targets 'x="$(echo "a > b")"')" "" "targets: no write from > inside nested quotes"
eq "$(targets 'until [ "$(psql db -Atc "select 1 where t > now() - interval 1")" = "0" ]; do sleep 5; done')" "" "targets: the polling loop of #382"
eq "$(targets 'echo "$(cat a)" > out.txt')" "$FX/out.txt" "targets: a redirect after a quoted substitution"
eq "$(targets 'x="$(echo "a > b")" > c.txt')" "$FX/c.txt" "targets: a redirect after nested quotes"
eq "$(targets 'echo $(cat a > in.txt)')" "$FX/in.txt" "targets: a redirect inside an unquoted substitution"
}
rm -rf "$FX"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
