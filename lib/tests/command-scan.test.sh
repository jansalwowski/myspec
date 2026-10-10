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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
