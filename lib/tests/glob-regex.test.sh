#!/usr/bin/env bash
# Fixture for lib/glob-regex.sh, the one glob compiler behind
# checks[].paths (verify-before-stop.sh), hooks.markCodeChanged.ignorePaths
# (mark-code-changed.sh) and isolation.provision.clean
# (worktree-provision.sh). Until it existed each script had its own copy, and
# they disagreed: `src/**.ts` crossed directories in two of them and not in
# the third, and `gen/` matched everything under gen/ in one and nothing in
# the others.
#
# Usage: glob-regex.test.sh [path-to-glob-regex.sh]

set -uo pipefail

LIB="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../glob-regex.sh}"
if [ ! -f "$LIB" ]; then
  echo "FATAL: glob-regex.sh not found: $LIB" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$LIB"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

case_() {  # case_ <glob> <path> <yes|no>
  local re got
  if ! re=$(glob_regex "$1"); then
    fail "'$1' should compile"
    return
  fi
  if [[ "$2" =~ $re ]]; then got=yes; else got=no; fi
  [ "$got" = "$3" ] && ok || fail "'$1' vs '$2' should be $3 (got $got, ERE $re)"
}

unusable() {  # unusable <glob>
  local out rc=0
  out=$(glob_regex "$1") || rc=$?
  [ "$rc" -ne 0 ] && [ -z "$out" ] && ok || fail "'$1' is unusable (got rc=$rc, '$out')"
}

# ** inside a segment is a plain *: it does not cross a directory.
case_ 'src/**.ts' src/x/y.ts no
case_ 'src/**.ts' src/y.ts yes
# A whole-segment ** crosses any number of directories, none included.
case_ 'src/**/*.ts' src/x/y.ts yes
case_ 'src/**/*.ts' src/y.ts yes
case_ 'a/**/z.ts' a/b/c/z.ts yes
case_ '**/*.tsbuildinfo' a/b/c/d.tsbuildinfo yes
case_ '**/*.tsbuildinfo' d.tsbuildinfo yes
case_ 'api/**' api/a.php yes
case_ 'api/**' api/v1/a.php yes
case_ 'api/**' apis/a.php no
case_ '**' any/thing.txt yes
# A trailing / is everything under the directory.
case_ 'gen/' gen/a.php yes
case_ 'gen/' gen/x/a.php yes
case_ 'gen/' generated/a.php no
case_ 'gen/' gen no
# * and ? stay within one segment, and a glob matches from the root.
case_ '*.ts' a.ts yes
case_ '*.ts' a/b.ts no
case_ '*.gen.ts' x.gen.ts yes
case_ '*.gen.ts' codegen.ts no
case_ 'v?.ts' v1.ts yes
case_ 'v?.ts' v12.ts no
case_ 'v?.ts' v/.ts no
# A leading ./ is dropped.
case_ './src/*.ts' src/a.ts yes
# Every other character is literal (PR #243: c++ is a literal suffix, and
# the ERE metacharacters match only themselves).
case_ '*.c++' a.c++ yes
case_ '*.c++' a.cc no
case_ '*.c++' a.c+++ no
case_ 'src/(old)/**' 'src/(old)/a.ts' yes
case_ 'src/(old)/**' src/old/a.ts no
# shellcheck disable=SC2016 # literal text, not an expansion
case_ 'lib/a$b.ts' 'lib/a$b.ts' yes
case_ 'a+b.txt' a+b.txt yes
case_ 'a+b.txt' aab.txt no
case_ 'x[1].log' 'x[1].log' yes
case_ 'x[1].log' x1.log no
case_ '{api,web}/**' '{api,web}/a.ts' yes
case_ '{api,web}/**' api/a.ts no
case_ 'a|b' 'a|b' yes
case_ 'a|b' a no
case_ '^a' '^a' yes
case_ 'a\b' 'a\b' yes
case_ 'a.b' axb no
# Unusable globs.
unusable ''
unusable './'
unusable /abs/*.ts
unusable '../x/**'
unusable 'a/../b'

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
