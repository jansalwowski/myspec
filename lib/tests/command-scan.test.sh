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
# word (#382): the inner quotes pair up, so a `>` in the inner string is not
# a redirect. A substitution inside double quotes is split open like an
# unquoted one, so the commands in it are still scanned.
# segs <command>: the plain scan's non-empty segments, as "<sep> <text>" / …
segs() {
  printf '%s' "$1" | sanitize_command | split_segments \
    | awk -F'\t' '$2 ~ /[^ ]/ { printf "%s%s %s", (n++ ? " / " : ""), $1, $2 }'
}
# shellcheck disable=SC2016 # literal $( ) and backticks are the point
{
eq "$(segs 'x="$(echo "a > b")"')" '^ x=Q$ / ( echo Q / ) Q' "nest: quotes inside \$( ) in a double-quoted word"
eq "$(segs 'until [ "$(psql db -Atc "select 1 where t > now()")" = "0" ]; do sleep 5; done')" '^ until [ Q$ / ( psql db -Atc Q / ) Q = Q ] / |  do sleep 5 / |  done' "nest: the polling loop of #382"
eq "$(segs 'x="$(a "$(b "$(c "d > e")")")"')" '^ x=Q$ / ( a Q$ / ( b Q$ / ( c Q / ) Q / ) Q / ) Q' "nest: three levels deep"
eq "$(segs 'x="`echo "a > b"`"')" '^ x=Q / | echo Q / | Q' "nest: quotes inside backticks in a double-quoted word"
eq "$(segs 'x="${y:-"a > b"}"')" '^ x=Q' "nest: quotes inside \${ } in a double-quoted word"
eq "$(segs "echo \"\${a:-\${b:-it's}}\"; git checkout main")" '^ echo Q / |  git checkout main' "nest: a quote in a nested \${ } is literal"
eq "$(segs "x=\"\$(printf \$'a\\'b')\"; git checkout main")" '^ x=Q$ / ( printf $Q / ) Q / |  git checkout main' "nest: \\' inside \$'…' does not end it"
eq "$(segs 'echo "$(bash -c "cd x && git checkout main")"')" '^ echo Q$ / ( bash -c Q / ) Q' "nest: a quoted substitution's command is scanned"
eq "$(segs 'x="$(git branch -D x)"')" '^ x=Q$ / ( git branch -D x / ) Q' "nest: a verb inside a quoted substitution is seen"
eq "$(segs 'x="$(case $y in a) echo "q";; esac)"')" '^ x=Q$ / ( case $y in a / |  echo Q / |  esac / ) Q' "nest: a case pattern does not close \$( )"
eq "$(segs 'x="$(( (1) > 0 ))" > o')" '^ x=Q > o' "nest: \$(( )) with inner parens stays in the word"
eq "$(segs $'m="$(cat <<\'EOF\'\nit\'s "x" ) > y\nEOF\n)" > o')" '^ m=Q$ / ( cat  Q  / ) Q > o' "nest: a heredoc body inside \$( ) in quotes"
eq "$(segs $'m="$(echo hi # it\'s )\n)" > o')" '^ m=Q$ / ( echo hi  / ) Q > o' "nest: a comment inside \$( ) in quotes"
eq "$(segs 'echo "$(cat a)" > out.txt')" '^ echo Q$ / ( cat a / ) Q > out.txt' "nest: a redirect after the word is still seen"
eq "$(segs 'echo $(cat a > b) "c"')" '^ echo $ / ( cat a > b / )  Q' "nest: an unquoted \$( ) is still split open"
}
# Past the depth cap the scan fails closed: every word is exposed.
# shellcheck disable=SC2016 # literal $( ) is the point
{
deep=$(i=0; while [ "$i" -lt 3000 ]; do printf '"$('; i=$((i + 1)); done; printf 'git checkout main')
out=$(printf '%s' "$deep" | sanitize_command)
case "$out" in *'$(git checkout main'*) ok ;; *) fail "nest: 3000 levels fail closed (got ${#out} bytes)" ;; esac
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
aligned 'x="pre $(echo "a > b; c && d") post" y z' "nested quotes with separators"
aligned 'x="$(a "$(b "c | d")")" && cd "e f" && echo "`g "h i"`" > o' "deep nesting and a backtick"
aligned $'git commit -m "$(cat <<\'EOF\'\nsubject (x) && y\n\nbody; it\'s\nEOF\n)" && echo ok > o' "a heredoc commit message"
aligned "x=\"\${a:-\${b:-it's}}\" \"\$(case \$y in a) printf \$'q\\'r';; esac)\" w" "\${ }, case and \$'…'"
}
# shellcheck disable=SC2016 # literal $( ) is the point
{
line=$(printf '%s' 'cd "$(echo "a b")"' | sanitize_command keep | split_segments | sed -n 2p)
eq "$(decode_word "${line#*$'\t'echo }")" 'a b' "keep: a quoted word inside \$( ) decodes to its text"
line=$(printf '%s' 'echo "$(bash -c "cd x && git checkout main")"' | sanitize_command keep | split_segments | sed -n 2p)
eq "$(decode_word "${line#*$'\t'bash -c }")" 'cd x && git checkout main' "keep: a bash -c payload inside quoted \$( )"
}

# bash_write_targets over the scans: the targets of a nested-quote command.
# shellcheck source=lib/hook-core.sh
. "$HERE/../hook-core.sh"
# shellcheck source=lib/bash-write-targets.sh
. "$HERE/../bash-write-targets.sh"
FX=$(mktemp -d)
trap 'rm -rf "$FX"' EXIT
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
eq "$(targets 'x="$(cat a > q.txt)"')" "$FX/q.txt" "targets: a redirect inside a quoted substitution"
}

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
