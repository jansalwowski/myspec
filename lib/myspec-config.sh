#!/usr/bin/env bash
# myspec-config.sh
# The one reader for myspec settings (docs/project-settings-design.md,
# principle 4). Every hook and lib script reads a setting through this helper,
# or through lib/myspec-config.mjs, which has the same semantics; no script
# parses .myspec.json its own way.
#
# Usage:
#   "${CLAUDE_PLUGIN_ROOT}"/lib/myspec-config.sh get <dotted.key> [--root <checkout>]
#
# Prints the effective value as compact JSON on stdout (null when no layer
# sets the key) and exits 0. Keys under `verification.` are read from
# .claude/verification.json, every other key from .myspec.json. --root
# defaults to the top of the current checkout, so a branch that changes a
# setting is read with its own setting.
#
# Layers, in order; a later layer wins key by key (LAYERS below):
#   default   the defaults in lib/myspec-config.schema.json
#   project   .myspec.json and .claude/verification.json in --root
#   session   the MYSPEC_* overrides the schema's env block lists
# The list is ordered data, so a per-machine layer can slot in between
# project and session without changing a caller. Objects merge key by key.
# A list merges by the schema's `merge` for that key: `extend` appends a
# later layer's entries (principle 3), `replace` lets the later layer win.
#
# Fail closed (principle 5): a file that is not a JSON object, or a value
# whose type the schema does not allow, is ignored in favour of the earlier
# layers, and the helper names the ignored key on stderr. Only keys at, above
# or below the requested one are named. Unknown keys pass through unchecked;
# validating them is doctor's job.
#
# Exit: 0 with the value, 2 on a usage error, a missing jq or a missing schema.

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCHEMA="$HERE/myspec-config.schema.json"

usage() {
  echo "usage: myspec-config.sh get <dotted.key> [--root <checkout>]" >&2
  exit 2
}

if [ $# -lt 2 ] || [ "$1" != "get" ]; then usage; fi
KEY="$2"
shift 2
ROOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || usage; ROOT="$2"; shift 2 ;;
    *) usage ;;
  esac
done
case "$KEY" in
  ''|.*|*.|*..*) echo "myspec-config: '$KEY' is not a dotted key" >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "myspec-config: jq is required" >&2; exit 2; }
[ -f "$SCHEMA" ] || { echo "myspec-config: schema not found at $SCHEMA" >&2; exit 2; }

if [ -z "$ROOT" ]; then
  ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)
fi
[ -d "$ROOT" ] || { echo "myspec-config: --root '$ROOT' is not a directory" >&2; exit 2; }

# file_args <name> <path> -> jq args binding $<name> to the file's text and
# $<name>_exists to whether it exists (a missing file is not an unreadable one).
# A file that exists but cannot be read binds empty text, which parse() then
# ignores and names, as the Node reader does; --rawfile on it would abort.
FILE_ARGS=()
file_args() {
  if [ -f "$2" ] && [ -r "$2" ]; then
    FILE_ARGS+=(--rawfile "$1" "$2" --argjson "$1_exists" true)
  elif [ -e "$2" ]; then
    FILE_ARGS+=(--arg "$1" "" --argjson "$1_exists" true)
  else
    FILE_ARGS+=(--arg "$1" "" --argjson "$1_exists" false)
  fi
}
file_args project "$ROOT/$(jq -r '.files.project' "$SCHEMA")"
file_args verification "$ROOT/$(jq -r '.files.verification' "$SCHEMA")"

OUT=$(jq -nr --slurpfile schema "$SCHEMA" --arg req "$KEY" "${FILE_ARGS[@]}" '
  $schema[0] as $S
  | ($req | split(".")) as $reqp

  # getp(path) -> {found, v}: a value is found only through objects.
  | def getp($p): reduce $p[] as $s ({found: true, v: .};
      if .found and (.v | type) == "object" and (.v | has($s)) then .v = .v[$s] else {found: false} end);
    def relevant($k): $k == $req or ($k | startswith($req + ".")) or ($req | startswith($k + "."));
    def fileof($k): if ($k | split(".")[0]) == "verification" then "verification" else "project" end;
    def plainkeys: $S.keys | to_entries[] | select(.key | contains("[]") | not);

    # parse(text; exists; name) -> {data, warnings}: an unreadable file is
    # ignored whole, named only when the requested key lives in it.
    def parse($text; $exists; $name):
      if ($exists | not) then {data: {}, warnings: []}
      else (try ($text | fromjson) catch null) as $d
        | if ($d | type) == "object" then {data: $d, warnings: []}
          else {data: {}, warnings: (if fileof($req) == $name
            then ["\($S.files[$name]) is not a JSON object; \($req) falls back to the default"] else [] end)}
          end
      end;

    # sanitize: drop each value whose type the schema does not allow, and any
    # non-object standing where the schema expects an object.
    def sanitize:
      reduce plainkeys as $e (.;
        ($e.key | split(".")) as $segs
        | reduce range(0; $segs | length) as $i (. + {stop: false};
            if .stop then . else
              $segs[0:$i + 1] as $p
              | (.data | getp($p)) as $g
              | ($i == ($segs | length) - 1) as $leaf
              | if ($g.found | not) then .stop = true
                elif ($leaf | not) and ($g.v | type) == "object" then .
                elif $leaf and any($e.value.type[]; . == ($g.v | type)) then .
                else .data |= delpaths([$p]) | .stop = true
                  | ($p | join(".")) as $at
                  | .warnings += (if relevant($at) then
                      ["ignoring \($at) in \($S.files[$e.value.file]): expected \(if $leaf then ($e.value.type | join(" or ")) else "an object" end), got \($g.v | type); \(if $leaf then "it uses the default" else "the keys under it use their defaults" end)"]
                    else [] end)
                end
            end)
        | del(.stop));

    def layer_default:
      {name: "default", warnings: [],
       data: (reduce plainkeys as $e ({}; if ($e.value | has("default"))
         then setpath($e.key | split("."); $e.value.default) else . end))};

    def layer_project:
      parse($project; $project_exists; "project") as $p
      | parse($verification; $verification_exists; "verification") as $v
      | {name: "project", data: ($p.data + {verification: $v.data}), warnings: ($p.warnings + $v.warnings)}
      | sanitize
      | if ($verification_exists | not) then del(.data.verification) else . end;

    def layer_session:
      {name: "session", warnings: [],
       data: (reduce ($S.env | to_entries[] | select(.value.kind == "override")) as $e ({};
         ($ENV[$e.key] // "") as $val
         | if ($val | test($e.value.match)) then setpath($e.value.key | split("."); $e.value.value) else . end))};

    # merge(a; b; path): b over a, key by key; a list extends or replaces.
    def merge($a; $b; $path):
      if ($a | type) == "object" and ($b | type) == "object" then
        reduce ($b | keys_unsorted[]) as $k ($a;
          .[$k] = (if has($k) then merge(.[$k]; $b[$k]; $path + [$k]) else $b[$k] end))
      elif ($a | type) == "array" and ($b | type) == "array"
          and $S.keys[$path | join(".")].merge == "extend" then
        $a + [$b[] as $x | select(any($a[]; . == $x) | not) | $x]
      else $b end;

    # The ordered layer list. A later layer wins.
    [layer_default, layer_project, layer_session] as $LAYERS
    | (reduce $LAYERS[] as $l ({}; merge(.; $l.data; []))) as $merged
    | ([$LAYERS[].warnings[]] | reduce .[] as $w ([]; if index([$w]) then . else . + [$w] end)) as $warnings
    | ($merged | getp($reqp)) as $g
    | ($warnings[] | "W" + .), ("V" + (if $g.found then $g.v else null end | tojson))
')

while IFS= read -r line; do
  case "$line" in
    W*) printf 'myspec-config: %s\n' "${line#W}" >&2 ;;
    V*) printf '%s\n' "${line#V}" ;;
  esac
done <<< "$OUT"
