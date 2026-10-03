#!/usr/bin/env bash
# stop-gate/provision.sh
# lint: sourced under set -euo pipefail
# Sourced by hooks/verify-before-stop.sh, after lib/hook-core.sh; never run.
# Linked dependencies (docs/stop-gate.md, R8). worktree-provision.sh records
# each link it makes, with the hash of every lockfile that pinned it, in the
# worktree's .claude/state/provision.json. A recorded link that no longer
# resolves to its recorded target, or a recorded lockfile whose hash changed
# in the source checkout or in this one, means the checks would run against a
# dependency tree that no longer matches this tree: block, and name the script
# that refreshes the record. Only links the record lists are compared, and
# only in a linked worktree; a link provision did not make is doctor's
# finding (link-unrecorded), not this gate's. A recorded path that is no
# longer a link (a real install replaced it) is not compared. No `verified`
# event is recorded on a block, so the block persists until provision runs
# again. Tests: lib/tests/stop-gate-arm.test.sh (provision_stale) and
# hooks/tests/verify-before-stop.test.sh.

# provision_stale <root> -> one "path (reason)" per stale recorded link.
# Fails, printing the reason, when the record cannot be read.
provision_stale() {
  local root="$1" record="$1/.claude/state/provision.json" src kind path a b cur sum
  src=$(jq -er '.source | strings' "$record" 2>/dev/null) || { printf 'the record has no source\n'; return 1; }
  while IFS=$'\t' read -r kind path a b; do
    [ -L "$root/$path" ] || continue
    case "$kind" in
      link)
        if [ -d "$root/$path" ]; then
          cur=$(physical_dir "$root/$path") || cur=""
        elif [ -e "$root/$path" ]; then
          cur=$(physical_path "$(readlink "$root/$path")" "$(dirname "$root/$path")") || cur=""
        else
          cur=""
        fi
        [ "$cur" = "$a" ] || printf '%s (the link no longer points into %s)\n' "$path" "$src"
        ;;
      lock)
        for cur in "$src/$a" "$root/$a"; do
          sum=$(file_sha256 "$cur") || sum=""
          if [ "$sum" != "$b" ]; then
            printf '%s (%s changed)\n' "$path" "$a"
            break
          fi
        done
        ;;
    esac
  done < <(jq -r '.links[]? | select(type == "object" and (.path | type) == "string" and .path != "")
      | ["link", .path, (.target // "" | tostring), ""],
        (.path as $p | .lockfiles // {} | objects | to_entries[] | ["lock", $p, .key, (.value | tostring)])
      | @tsv' "$record" 2>/dev/null) || { printf 'the record is not valid JSON\n'; return 1; }
}

# provision_check <root>... -> blocks (decision_block exits) on the first
# linked worktree whose provision record is stale or unreadable.
provision_check() {
  local root stale script="$HOOK_LIB/worktree-provision.sh"
  for root in "$@"; do
    [ -f "$root/.claude/state/provision.json" ] || continue
    if ! checkout_facts "$root" || [ "$CF_LINKED" -ne 1 ]; then continue; fi
    if ! stale=$(provision_stale "$root"); then
      decision_block 'Symlinked dependency directory in %s: the provision record %s cannot be read (%s). Re-run provision: %s "%s"' \
        "$root" "$root/.claude/state/provision.json" "$stale" "$script" "$root"
    fi
    if [ -n "$stale" ]; then
      decision_block 'Symlinked dependency directory in %s: dependencies in %s were provisioned from lockfiles that changed, or their link moved, so lint, type-check and test results here would describe a different dependency tree:\n\n%s\n\nRe-run provision, which links again where the lockfiles match and says what to install where they do not: %s "%s"' \
        "$root" "$(printf '%s\n' "$stale" | sed 's/ (.*//' | sort -u | paste -sd, - | sed 's/,/, /g')" "$stale" "$script" "$root"
    fi
  done
}
