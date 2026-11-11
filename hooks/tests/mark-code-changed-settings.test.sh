#!/usr/bin/env bash
# Settings shortcut of mark-code-changed.sh. load_settings starts the settings
# reader (a bash process and several jq ones, a third of an Edit hook's time)
# only when .myspec.json can set hooks.markCodeChanged: its text names the key,
# or holds a \u escape that could spell it. No layer but the project file sets
# the key, so every other file gives the schema's defaults, which are the
# hook's own. This suite holds both halves: for each config the hook
# classifies writes as the reader's value says, and the reader runs only for
# the configs that need it. The reader is counted through a copy of lib/ whose
# myspec-config.sh logs the key it was asked for.
#
# Usage: mark-code-changed-settings.test.sh [path-to-hook]

set -uo pipefail

HOOK="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../mark-code-changed.sh}"
REAL_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)"

ROOT=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

# The plugin root the hook runs from: lib/ as shipped, but the reader logs.
PLUG="$ROOT/plugin"
mkdir -p "$PLUG/lib"
for f in "$REAL_LIB"/*; do
  [ "${f##*/}" = myspec-config.sh ] || ln -s "$f" "$PLUG/lib/${f##*/}"
done
READS="$ROOT/reads.log"
cat > "$PLUG/lib/myspec-config.sh" <<WRAP
#!/usr/bin/env bash
printf '%s\n' "\$2" >> "$READS"
exec bash "$REAL_LIB/myspec-config.sh" "\$@"
WRAP
export CLAUDE_PLUGIN_ROOT="$PLUG"

write() {  # write <sid> <cwd> <file-path>
  jq -nc --arg s "$1" --arg c "$2" --arg f "$3" \
    '{hook_event_name: "PostToolUse", session_id: $s, tool_name: "Edit", cwd: $c, tool_input: {file_path: $f, old_string: "a", new_string: "b"}}' \
    | bash "$HOOK" >/dev/null 2>&1
}

# kind <dir> <sid> <rel> -> the kind the session recorded for that write.
kind() {
  find "$1" -path "*/.claude/state/sessions/$2.jsonl" -exec cat {} + 2>/dev/null \
    | jq -r --arg r "$3" 'select(.t == "write" and .rel == $r) | .kind' 2>/dev/null | tr '\n' ' '
}

# reads -> how often the hook asked the reader for hooks.markCodeChanged.
reads() {
  grep -cxF -- 'hooks.markCodeChanged' "$READS" 2>/dev/null || true
}

# check <name> <checkout> <config root> <twig kind> <generated kind> <reader: yes|no>
# Writes a default-extension file, a .twig file and a file under generated/
# in <checkout>, and holds the recorded kinds against the ones given and
# against the reader's own value for <config root>.
check() {
  local name="$1" dir="$2" cfg="$3" twig="$4" gen="$5" reader="$6" val want_twig want_gen n
  mkdir -p "$dir/src" "$dir/templates" "$dir/generated"
  : > "$READS"
  write "s-$name" "$dir" "$dir/src/a.ts"
  write "s-$name" "$dir" "$dir/templates/p.twig"
  write "s-$name" "$dir" "$dir/generated/g.ts"
  n=$(reads)

  [ "$(kind "$ROOT/$name" "s-$name" src/a.ts)" = "code " ] && ok || fail "$name: a default extension is code (got: $(kind "$ROOT/$name" "s-$name" src/a.ts))"
  [ "$(kind "$ROOT/$name" "s-$name" templates/p.twig)" = "$twig " ] && ok \
    || fail "$name: templates/p.twig is $twig (got: $(kind "$ROOT/$name" "s-$name" templates/p.twig))"
  [ "$(kind "$ROOT/$name" "s-$name" generated/g.ts)" = "$gen " ] && ok \
    || fail "$name: generated/g.ts is $gen (got: $(kind "$ROOT/$name" "s-$name" generated/g.ts))"

  # The same two answers from the reader's effective value, defaults included.
  val=$(bash "$REAL_LIB/myspec-config.sh" get hooks.markCodeChanged --root "$cfg" 2>/dev/null)
  want_twig=$(printf '%s' "$val" | jq -r 'if ((.extraCodeExtensions // []) | index("twig")) then "code" else "file" end')
  want_gen=$(printf '%s' "$val" | jq -r 'if ((.ignorePaths // []) | index("generated/**")) then "file" else "code" end')
  [ "$twig/$gen" = "$want_twig/$want_gen" ] && ok || fail "$name: the reader's value gives $want_twig/$want_gen, the case expects $twig/$gen"

  case "$reader" in
    no)  [ "$n" = 0 ] && ok || fail "$name: the settings reader does not run (ran $n times)" ;;
    yes) [ "$n" -ge 1 ] && ok || fail "$name: the settings reader runs" ;;
  esac
}

# repo <name> <.myspec.json text> -> a fresh repository with that config.
repo() {
  mkdir -p "$ROOT/$1"
  git init -q -b main "$ROOT/$1"
  printf '%s\n' "$2" > "$ROOT/$1/.myspec.json"
}

# case_of <name> <.myspec.json text> <twig kind> <generated kind> <reader>
case_of() {
  repo "$1" "$2"
  check "$1" "$ROOT/$1" "$ROOT/$1" "$3" "$4" "$5"
}

SET='"extraCodeExtensions":["twig"],"ignorePaths":["generated/**"]'

# --- the key is absent: defaults, and no reader ---------------------------------
case_of absent      '{"aiDir":".ai","frameworkVersion":"3.0.0"}'                                    file code no
case_of other-hooks '{"aiDir":".ai","hooks":{"guardPublicPosts":{"privateIdentifiers":["acme"]}}}' file code no
case_of other-keys  '{"aiDir":".ai","isolation":{"worktreeRoot":"wt"},"statusDiff":false}'         file code no
case_of not-json    '{"aiDir": '                                                                    file code no

# --- the key is present: the reader decides -------------------------------------
case_of empty       '{"aiDir":".ai","hooks":{"markCodeChanged":{}}}'                      file code yes
case_of diff-true   '{"aiDir":".ai","hooks":{"markCodeChanged":{"statusDiff":true}}}'     file code yes
case_of diff-false  '{"aiDir":".ai","hooks":{"markCodeChanged":{"statusDiff":false}}}'    file code yes
case_of set         "{\"aiDir\":\".ai\",\"hooks\":{\"markCodeChanged\":{$SET}}}"          code file yes
case_of wrong-type  '{"hooks":{"markCodeChanged":{"extraCodeExtensions":"twig","ignorePaths":"generated/**"}}}' file code yes

# --- a \u escape can spell the key: the reader decides --------------------------
case_of escaped     "{\"hooks\":{\"markCode\\u0043hanged\":{$SET}}}"                      code file yes
case_of escape-else "{\"aiDir\":\".ai\",\"note\":\"caf\\u00e9\"}"                          file code yes

# --- the name in a value sets nothing -------------------------------------------
case_of in-value    '{"aiDir":".ai","note":"see hooks.markCodeChanged"}'                  file code yes

# --- a worktree without the file reads the primary checkout's -------------------
for pair in "wt-absent|{\"aiDir\":\".ai\"}|file|code|no" "wt-set|{\"hooks\":{\"markCodeChanged\":{$SET}}}|code|file|yes"; do
  IFS='|' read -r name json twig gen reader <<< "$pair"
  repo "$name" "$json"
  git -C "$ROOT/$name" config user.email t@t
  git -C "$ROOT/$name" config user.name t
  git -C "$ROOT/$name" commit -q --allow-empty -m init
  git -C "$ROOT/$name" worktree add -q "$ROOT/$name/.claude/worktrees/w" -b "w-$name"
  check "$name" "$ROOT/$name/.claude/worktrees/w" "$ROOT/$name" "$twig" "$gen" "$reader"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
