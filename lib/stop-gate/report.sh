#!/usr/bin/env bash
# stop-gate/report.sh
# lint: sourced under set -euo pipefail
# Sourced by hooks/verify-before-stop.sh, after lib/hook-core.sh; never run.
# What the stop gate prints: the memory and setup conformance blocks (R9),
# and the decision after the checks, a block or an approve with or without a
# systemMessage. Requirements: docs/stop-gate.md in the plugin repository.
# The block messages open with the fragments lib/friction-scan/scan.mjs
# matches on ("Memory conformance check failed", "Setup conformance check
# failed", "Verification did not pass"); keep them.
# shellcheck disable=SC2034 # GATE_DECIDED is read by finish_run (arm.sh)

# conformance_gates <repo root> -> blocks (decision_block exits) on memory or
# setup conformance errors under uncommitted changes.
# Memory: the index tables are generated and the ID allocator refuses on
# drift, so drift a session leaves behind (an unregenerated index, a memory
# without hook:, a duplicate ID) should surface here, in the session that
# caused it. Gated on uncommitted changes under the memory tree: pre-existing
# drift the agent never touched is bootstrap's to report. Only errors block
# (the doctor exits 1 on errors alone): a duplicate ID that lives only on
# stale branches is a warning, since no change in this session can fix it
# (#124).
# Setup: only the wiring and schema groups. A hook that is registered but
# missing, not executable, or fails bash -n is silently inert, and an
# unparseable .myspec.json or verification.json degrades this very gate: all
# of them are damage the session just did and can undo now. Framework drift
# is excluded (its usual cause is a pending /myspec:update), and so is the
# features group, which reads a file outside the trigger below. Gated on
# uncommitted changes to the harness config, as the memory check is.
# Both use $(...) and -n, not `| grep -q .`: grep exits on the first line, a
# status longer than a pipe buffer then kills git with SIGPIPE, and under
# pipefail the `if` read false and skipped the gate.
conformance_gates() {
  local root="$1" doctor="$1/.claude/lib/memory-doctor.mjs" setup="$1/.claude/lib/setup-doctor.mjs" ai out
  [ -f "$root/.myspec.json" ] && command -v node >/dev/null 2>&1 || return 0
  if [ -f "$doctor" ]; then
    # aiDir is required since 2.0; .ai is the documented default when absent,
    # the same resolution memory-files.mjs uses.
    ai=$(ai_dir "$root")
    if [ -n "$ai" ] && [ -n "$(git -C "$root" status --porcelain -- "$ai/memory" 2>/dev/null)" ]; then
      if ! out=$(cd "$root" && node "$doctor" --quiet 2>&1); then
        decision_block 'Memory conformance check failed for changes under %s/memory. Fix these before stopping (node .claude/lib/memory-index.mjs regenerates the tables; the doctor names the rest):\n\n%s' "$ai" "$(printf '%s' "$out" | tail -30)"
      fi
    fi
  fi
  if [ -f "$setup" ] && [ -n "$(git -C "$root" status --porcelain -- .claude .myspec.json 2>/dev/null)" ]; then
    if ! out=$(cd "$root" && node "$setup" --quiet wiring schema 2>&1); then
      decision_block 'Setup conformance check failed for changes under .claude/ or .myspec.json. Each of these makes a hook or a gate silently stop working, so fix them before stopping:\n\n%s' "$(printf '%s' "$out" | tail -30)"
    fi
  fi
}

# report_decision -> prints the decision and exits 0. Reads the run.sh
# arrays, the attribute.sh notes and SCOPE_NOTES. Sets GATE_DECIDED=1 just
# before the decision goes out: finish_run records `verified` only then, so a
# hook that dies on the way (set -e) leaves its checkouts armed.
report_decision() {
  local scope="" names="" timed unver unrun ran details="" notes entry headline message
  # One line per note, deduplicated (a note from the reader repeats per root).
  if [ "${#SCOPE_NOTES[@]}" -gt 0 ]; then
    scope="Scope: $(printf '%s\n' "${SCOPE_NOTES[@]}" | LC_ALL=C awk '!seen[$0]++ { printf "%s%s", (n++ ? " " : ""), $0 }')"
  fi

  if [ ${#FAILED_CHECKS[@]} -gt 0 ] || [ ${#TIMED_OUT_CHECKS[@]} -gt 0 ] || [ ${#UNVERIFIABLE_CHECKS[@]} -gt 0 ] \
      || [ ${#NOT_RUN_CHECKS[@]} -gt 0 ]; then
    # The headline separates the outcomes: "failed" is a result, "timed out"
    # and "not run" are the absence of one.
    if [ ${#FAILED_CHECKS[@]} -gt 0 ]; then
      names=$(printf '%s, ' "${FAILED_CHECKS[@]}"); names="failed: ${names%, }"
    fi
    if [ ${#TIMED_OUT_CHECKS[@]} -gt 0 ]; then
      # Each entry carries its own cap: a check the budget cut short already
      # names the seconds it got, the rest ran to the per-check cap.
      timed=""
      for entry in "${TIMED_OUT_CHECKS[@]}"; do
        case "$entry" in
          *"(at the gate budget, "*) timed+="$entry, " ;;
          *) timed+="$entry (after ${CHECK_CAP_SECONDS}s), " ;;
        esac
      done
      timed="timed out, result unknown: ${timed%, }"
      names="${names:+$names; }$timed"
    fi
    if [ ${#UNVERIFIABLE_CHECKS[@]} -gt 0 ]; then
      unver=$(printf '%s, ' "${UNVERIFIABLE_CHECKS[@]}"); unver="not run, unverifiable here: ${unver%, }"
      names="${names:+$names; }$unver"
    fi
    # A check the budget left unrun is not a pass (R13): name what ran and
    # what did not.
    if [ ${#NOT_RUN_CHECKS[@]} -gt 0 ]; then
      unrun=$(printf '%s, ' "${NOT_RUN_CHECKS[@]}"); unrun=${unrun%, }
      names="${names:+$names; }not run, gate budget of ${GATE_BUDGET_SECONDS}s spent: $unrun"
      ran="No check ran."
      if [ ${#RAN_CHECKS[@]} -gt 0 ]; then
        ran=$(printf '%s, ' "${RAN_CHECKS[@]}"); ran="Checks that ran: ${ran%, }."
      fi
      FAILED_OUTPUT+=("[gate budget] The stop gate's time budget, ${GATE_BUDGET_SECONDS}s for every check in every checkout, ran out before these checks started: $unrun. $ran A check that did not run is not a pass, and this is not a test failure. Run the checks that did not run directly and report their results; if the checks together take this long, reduce their runtime (paths, diffCommand). Do not raise the budget.")
    fi
    # Real newline-delimited separators: a multi-char IFS join uses only its
    # first character (4eb8ccb).
    for entry in "${FAILED_OUTPUT[@]}"; do
      details+="${entry}"$'\n---\n'
    done
    details=${details%$'\n---\n'}
    notes="${scope:+$scope$'\n\n'}"
    for entry in ${WARN_NOTES[@]+"${WARN_NOTES[@]}"}; do
      notes+="${entry}"$'\n\n'
    done
    if [ "$BLOCKING_FAILURE" -eq 0 ]; then
      # Non-blocking: no decision block, so the stop proceeds; systemMessage
      # surfaces the failure to the user. When the budget only left checks
      # unrun, nothing failed, and the headline says so.
      headline="Verification failing"
      if [ ${#FAILED_CHECKS[@]} -eq 0 ] && [ ${#TIMED_OUT_CHECKS[@]} -eq 0 ] && [ ${#UNVERIFIABLE_CHECKS[@]} -eq 0 ]; then
        headline="Verification incomplete"
      fi
      message=$(printf "%s (%s).\n\n%s%s" "$headline" "$names" "$notes" "$details" | jq -Rs .)
      GATE_DECIDED=1
      echo "{\"decision\": \"approve\", \"systemMessage\": $message}"
      exit 0
    fi
    if [ "${#BLOCK_NOTES[@]}" -gt 0 ]; then
      for entry in "${BLOCK_NOTES[@]}"; do
        notes+="${entry}"$'\n\n'
      done
      notes+="Fix what your changes broke. Do not edit files changed outside this session to make a check pass: another session sharing this checkout may be working on them. If a failure comes from those changes, say so and stop. A Bash side effect (an install, code generation) is not recorded as this session's write, so if you made one of those changes, it is yours."$'\n\n'
    fi
    GATE_DECIDED=1
    decision_block "Verification did not pass (%s). Fix the failures your changes caused before completing; for a timeout or a check not run, get the real result first.\n\n%s%s" "$names" "$notes" "$details"
  fi

  if [ -n "$scope" ]; then
    headline="Verification passed."
    [ "$CHECKS_RAN" -gt 0 ] || headline="Verification ran no check."
    message=$(printf '%s %s' "$headline" "$scope" | jq -Rs .)
    GATE_DECIDED=1
    echo "{\"decision\": \"approve\", \"systemMessage\": $message}"
    exit 0
  fi
  GATE_DECIDED=1
  echo '{"decision": "approve"}'
  exit 0
}
