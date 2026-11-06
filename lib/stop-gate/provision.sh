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
# again. A lockfile key recorded with a null hash is a pattern that matched
# nothing provision did not hash (an absent lockfile, or a glob): a file it
# matches on either side that the record does not list with a hash blocks,
# so a nested lockfile the branch adds later is compared too. A recorded
# lockfile that is gone on either side blocks as removed. Tests:
# lib/tests/stop-gate-arm.test.sh (provision_stale) and
# hooks/tests/verify-before-stop.test.sh. Below: a dependency directory
# with nothing installed (deps_note, #239, #375).

# dep_dir_uninstalled: what counts as nothing installed (lib/dep-dir.sh).
# shellcheck source=lib/dep-dir.sh
. "$HOOK_LIB/dep-dir.sh"

# provision_stale <root> -> one "path (reason)" per stale recorded link.
# Fails, printing the reason, when the record cannot be read.
provision_stale() {
  local root="$1" record="$1/.claude/state/provision.json" src kind path a b cur sum m side
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
          if [ ! -e "$cur" ]; then
            printf '%s (%s removed)\n' "$path" "$a"
            break
          fi
          sum=$(file_sha256 "$cur") || sum=""
          if [ "$sum" != "$b" ]; then
            printf '%s (%s changed)\n' "$path" "$a"
            break
          fi
        done
        ;;
      absent)
        # b: the keys this link recorded with a hash, \037-separated.
        m=""
        while IFS= read -r cur; do
          [ -n "$cur" ] || continue
          case $'\037'"$b"$'\037' in
            *$'\037'"$cur"$'\037'*) ;;
            *) m=$cur; break ;;
          esac
        done < <(for side in "$src" "$root"; do lock_paths_for "$side" "$a"; done | sort -u)
        [ -z "$m" ] || printf '%s (%s appeared)\n' "$path" "$m"
        ;;
    esac
  done < <(jq -r '.links[]? | select(type == "object" and (.path | type) == "string" and .path != "")
      | ["link", .path, (.target // "" | tostring), ""],
        (.path as $p | (.lockfiles // {} | objects) as $l
          | ([$l | to_entries[] | select(.value != null) | .key] | join("\u001f")) as $have
          | $l | to_entries[]
          | if .value == null then ["absent", $p, .key, $have] else ["lock", $p, .key, (.value | tostring)] end)
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

# Dependencies never installed in this tree (#239). A repository can track a
# placeholder inside its dependency directory (node_modules/.gitkeep, kept
# so a container's bind mount finds a directory its user owns), so a fresh
# worktree has the directory but nothing installed in it, and a check run
# there fails with the package manager's error, which reads like a code
# failure. The gate still runs the checks: one that does not need the host's
# dependencies (it runs in a container holding its own) passes as before.
# When a check of a checkout fails, deps_note adds, at the top of the
# verdict, which dependency directory holds nothing installed.
#
# DEPENDENCY_DIRS, one entry per ecosystem, as data:
#   <directory>|<manifests, comma-separated>
# The directory counts only beside one of its manifests. Whether it holds
# anything installed is dep_dir_uninstalled's call (lib/dep-dir.sh, the rule
# and the marker and cache lists worktree-provision.sh shares): no
# install-state marker, and nothing in it but files git tracks and known
# tool caches. Any other entry is an install, so an installer whose marker
# is not listed still counts as installed.
DEPENDENCY_DIRS=(
  'node_modules|package.json'
  'vendor|composer.json'
  'vendor|go.mod'
  'vendor/bundle|Gemfile'
  '.venv|pyproject.toml,requirements.txt,Pipfile,setup.py'
  'venv|pyproject.toml,requirements.txt,Pipfile,setup.py'
  'Pods|Podfile'
)

# deps_not_installed <dir> -> one `<dependency dir>\t<tracked entries,
# comma-separated, or empty>\t<cache entries, comma-separated, or empty>`
# line per DEPENDENCY_DIRS directory in <dir> that holds nothing installed.
# A link (provision's, checked by provision_check) is not one.
deps_not_installed() {
  local dir="$1" entry dep manifests m found held kind name names caches
  local -a ms
  for entry in "${DEPENDENCY_DIRS[@]}"; do
    IFS='|' read -r dep manifests <<< "$entry"
    found=0
    IFS=',' read -ra ms <<< "$manifests"
    for m in "${ms[@]}"; do
      [ ! -f "$dir/$m" ] || { found=1; break; }
    done
    [ "$found" = 1 ] || continue
    held=$(dep_dir_uninstalled "$dir" "$dep") || continue
    names=""
    caches=""
    while IFS=$'\t' read -r kind name; do
      case "$kind" in
        tracked) names="${names:+$names, }$name" ;;
        cache) caches="${caches:+$caches, }$name" ;;
      esac
    done <<< "$held"
    printf '%s\t%s\t%s\n' "$dep" "$names" "$caches"
  done
}

# deps_note <root> <failed index>: when checks of <root> failed (FAILED_CWDS
# from <failed index> on), adds to DEPS_NOTES each dependency directory in
# the root, or in a failed check's cwd, that holds nothing installed. In a
# linked worktree the fix it names is provisioning (worktree-provision.sh
# links or installs, and moves a cache-only directory aside, #375); in a
# main checkout, the project's install command.
DEPS_NOTES=()
deps_note() {
  local root="$1" from="$2" i d dirs=$'\n' line dep names caches held fix linked
  [ "${#FAILED_CWDS[@]}" -gt "$from" ] || return 0
  for ((i = from; i < ${#FAILED_CWDS[@]}; i++)); do
    d="$root${FAILED_CWDS[$i]:+/${FAILED_CWDS[$i]}}"
    case "$dirs" in *$'\n'"$d"$'\n'*) ;; *) dirs="$dirs$d"$'\n' ;; esac
  done
  case "$dirs" in *$'\n'"$root"$'\n'*) ;; *) dirs=$'\n'"$root$dirs" ;; esac
  # A subshell: checkout_facts sets CF_* globals the caller may still read.
  linked=$(checkout_facts "$root" && printf '%s' "$CF_LINKED") || linked=0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    # Split by hand: tab is IFS whitespace, so `read` would merge an empty
    # middle field into the next.
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      dep="${line%%$'\t'*}"
      line="${line#*$'\t'}"
      names="${line%%$'\t'*}"
      caches="${line#*$'\t'}"
      held="${names:+$names (tracked by git)}"
      [ -z "$caches" ] || held="${held:+$held and }tool caches only ($caches)"
      if [ "$linked" = 1 ]; then
        fix="Provision this worktree, which links or installs its dependencies: $HOOK_LIB/worktree-provision.sh \"$root\" (or install them in $d with the project's install command), then stop again."
      else
        fix="Install the dependencies in $d with the project's install command, then stop again."
      fi
      DEPS_NOTES+=("Dependencies not installed in this tree: $d/$dep holds ${held:-nothing} and no install-state marker, so the failures below may be the package manager's, not the code's. $fix")
    done < <(deps_not_installed "$d")
  done <<< "$dirs"
}
