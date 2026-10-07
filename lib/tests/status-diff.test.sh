#!/usr/bin/env bash
# Tests for lib/status-diff.sh (#276): what a Bash call wrote, from the
# working tree's changes before (status_capture) and after (status_changes)
# it, whatever the command text looked like.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/hook-core.sh
. "$HERE/../hook-core.sh"
# shellcheck source=lib/status-diff.sh
. "$HERE/../status-diff.sh"

ROOT=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }
eq()   { if [ "$1" = "$2" ]; then ok; else fail "$3 (got '$1', want '$2')"; fi; }

REPO="$ROOT/repo"
mkdir -p "$REPO/docs"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
printf 'a\n' > "$REPO/docs/a.md"
printf 'b\n' > "$REPO/docs/b.md"
printf 'c\n' > "$REPO/docs/c.md"
printf 'ignored/\n' > "$REPO/.gitignore"
git -C "$REPO" add -A
git -C "$REPO" commit -qm init

# changes <capture> -> status_changes as `<rel>=<before>` words, sorted.
changes() {
  status_changes "$1" | while IFS= read -r -d '' rel && IFS= read -r -d '' before; do
    printf '%s=%s\n' "$rel" "$before"
  done | LC_ALL=C sort | tr '\n' ' '
}
blob() { git -C "$REPO" hash-object -- "$1"; }
head_blob() { git -C "$REPO" rev-parse "HEAD:$1"; }

keep_md() { case "$2" in *.md) return 0 ;; esac; return 1; }

# --- a clean tree: what the call changes, with HEAD's content before -------------
status_capture "$REPO" > "$ROOT/cap1" && ok || fail "capture of a clean tree"
printf 'x\n' >> "$REPO/docs/a.md"
printf 'n\n' > "$REPO/docs/new.md"
mkdir -p "$REPO/ignored"
printf 'i\n' > "$REPO/ignored/x.md"
eq "$(changes "$ROOT/cap1")" "docs/a.md=$(head_blob docs/a.md) docs/new.md=- " \
  "a modified file (HEAD's blob before) and a new one (no file before); a gitignored one is not seen"

# --- a dirty tree: only what this call changed ------------------------------------
status_capture "$REPO" keep_md > "$ROOT/cap2"
A_BEFORE=$(blob docs/a.md)
git -C "$REPO" cat-file -e "$A_BEFORE" 2>/dev/null && ok || fail "keep: a kept file's capture is in the object store"
printf 'y\n' >> "$REPO/docs/a.md"
git -C "$REPO" add docs/new.md
eq "$(changes "$ROOT/cap2")" "docs/a.md=$A_BEFORE " \
  "a file dirty before and written again is one; one only staged (content unchanged) is not"

# --- deletion, revert, commit -----------------------------------------------------
status_capture "$REPO" keep_md > "$ROOT/cap3"
NEW_BEFORE=$(blob docs/new.md)
A_DIRTY=$(blob docs/a.md)
rm "$REPO/docs/new.md"
git -C "$REPO" checkout -q -- docs/a.md
printf 'c2\n' >> "$REPO/docs/c.md"
git -C "$REPO" commit -qam "commit c"
eq "$(changes "$ROOT/cap3")" "docs/a.md=$A_DIRTY docs/new.md=$NEW_BEFORE " \
  "a deleted file and a reverted one are writes; a file changed and committed in the call is not seen"

# --- files outside the keep set: compared by stat, never read (#305 review) ------
# field <capture> <rel> -> the state the capture holds for <rel>.
field() {
  tr '\0' '\n' < "$1" | awk -v r="$2" 'NR > 3 && (NR - 3) % 2 == 1 && $0 == r { getline; print; exit }'
}
printf 'data1\n' > "$REPO/big.bin"
printf 'kept\n' > "$REPO/docs/k.md"
status_capture "$REPO" keep_md > "$ROOT/cap8"
case "$(field "$ROOT/cap8" big.bin)" in
  s:*) ok ;;
  *) fail "an unkept file is captured as its stat signature (got '$(field "$ROOT/cap8" big.bin)')" ;;
esac
case "$(field "$ROOT/cap8" docs/k.md)" in
  "$(blob docs/k.md) s:"*) ok ;;
  *) fail "a kept file is captured as its blob and its signature (got '$(field "$ROOT/cap8" docs/k.md)')" ;;
esac
eq "$(changes "$ROOT/cap8")" "" "files dirty before and untouched by the call are not written"
touch "$REPO/docs/k.md"
eq "$(changes "$ROOT/cap8")" "" "a kept file whose stat moved but whose content did not is not written"
printf 'data2\n' > "$REPO/big.bin"
eq "$(changes "$ROOT/cap8")" "big.bin= " "an unkept file rewritten with the same size is written, with no before blob"
status_capture "$REPO" keep_md > "$ROOT/cap9"
touch "$REPO/big.bin"
eq "$(changes "$ROOT/cap9")" "big.bin= " "an unkept file is not read: a touch counts as a write"

# --- a kept file above the byte cap: stat only, no blob written ---------------------
printf 'a long doc\n' > "$REPO/docs/k.md"
K_BLOB=$(blob docs/k.md)
STATUS_DIFF_KEEP_MAX_BYTES=4 status_capture "$REPO" keep_md > "$ROOT/cap10"
case "$(field "$ROOT/cap10" docs/k.md)" in
  s:*) ok ;;
  *) fail "a kept file above STATUS_DIFF_KEEP_MAX_BYTES is captured by stat (got '$(field "$ROOT/cap10" docs/k.md)')" ;;
esac
git -C "$REPO" cat-file -e "$K_BLOB" 2>/dev/null && fail "a kept file above the cap is not written to the object store" || ok
printf 'more\n' >> "$REPO/docs/k.md"
eq "$(changes "$ROOT/cap10")" "docs/k.md= " "a write to a kept file above the cap is found, with no before blob"

# --- a stat that cannot answer: the paths are hashed instead ----------------------
STATUS_STAT=(false)
status_capture "$REPO" keep_md > "$ROOT/cap11"
eq "$(field "$ROOT/cap11" big.bin)" "$(blob big.bin)" "stat fallback: an unkept file is hashed"
K_BLOB=$(blob docs/k.md)
git -C "$REPO" cat-file -e "$K_BLOB" 2>/dev/null && ok || fail "stat fallback: a kept file's blob is still written"
eq "$(changes "$ROOT/cap11")" "" "stat fallback: nothing written, nothing found"
printf 'x\n' >> "$REPO/docs/k.md"
eq "$(changes "$ROOT/cap11")" "docs/k.md=$K_BLOB " "stat fallback: a write to a kept file is found with its blob"
unset STATUS_STAT
# shellcheck source=lib/status-diff.sh
. "$HERE/../status-diff.sh"
rm -f "$REPO/big.bin" "$REPO/docs/k.md"

# --- nothing changed --------------------------------------------------------------
status_capture "$REPO" > "$ROOT/cap4"
eq "$(changes "$ROOT/cap4")" "" "a call that changes nothing writes nothing"

# --- a tree too dirty to capture ---------------------------------------------------
for i in 1 2 3; do printf 'u\n' > "$REPO/u$i.txt"; done
STATUS_DIFF_MAX=2 status_capture "$REPO" > "$ROOT/cap5"
eq "$(tr '\0' '\n' < "$ROOT/cap5" | sed -n 3p)" "1" "a tree above STATUS_DIFF_MAX is marked, not hashed"
printf 'z\n' >> "$REPO/docs/b.md"
status_changes "$ROOT/cap5" > /dev/null && fail "a capped capture gives no changes" || ok
rm -f "$REPO"/u?.txt
git -C "$REPO" checkout -q -- docs/b.md

# --- an untracked file with an odd name -------------------------------------------
status_capture "$REPO" > "$ROOT/cap6"
printf 'q\n' > "$REPO/docs/sp ace.md"
printf 'q\n' > "$REPO/docs/new"$'\n'"line.md"
eq "$(status_changes "$ROOT/cap6" | tr '\0\n' '|^')" "docs/new^line.md|-|docs/sp ace.md|-|" "paths with a newline and a space"
rm -f "$REPO/docs/sp ace.md" "$REPO/docs/new"$'\n'"line.md"

# --- not a work tree, a missing capture, an unborn branch ------------------------
mkdir -p "$ROOT/plain"
status_capture "$ROOT/plain" > /dev/null && fail "outside a work tree there is no capture" || ok
status_changes "$ROOT/missing" > /dev/null && fail "a missing capture gives no changes" || ok
git init -q "$ROOT/unborn"
status_capture "$ROOT/unborn" > "$ROOT/cap7" && ok || fail "an unborn branch is captured"
printf 'x\n' > "$ROOT/unborn/f.md"
eq "$(status_changes "$ROOT/cap7" | tr '\0' ' ')" "f.md - " "on an unborn branch a new file had no content before"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
