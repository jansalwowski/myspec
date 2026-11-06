#!/usr/bin/env bash
# stop-gate/attribute.sh
# lint: sourced under set -euo pipefail
# Sourced by hooks/verify-before-stop.sh, after stop-gate/arm.sh and
# stop-gate/run.sh; never run. Decides whether a checkout's failures block or
# warn (docs/stop-gate.md, R4, R6 and R15, in the plugin repository). Tests:
# lib/tests/stop-gate-attribute.test.sh.
#
# Attribution (R4). When several sessions share one checkout, a red check may
# come from another session's uncommitted work (#198). T is the files this
# session wrote here (the ledger). F is the uncommitted and untracked files
# outside T. A failure is this session's when its output names a file in T,
# matched by basename, which errs toward blocking. The stop warns instead of
# blocking only when every failed check names a file in F and none names one
# in T, and nothing timed out, was refused or was left unrun by the budget. F is matched by its full
# repo-relative path, which errs toward blocking too: a package-relative path
# in a monorepo tool's output does not match.
# shellcheck disable=SC2034

# attribute_init -> the notes the report reads. A failure blocks unless the
# session is in a live feature-implement run or attribution clears it.
attribute_init() {
  BLOCKING_FAILURE=0
  WARN_NOTES=()
  BLOCK_NOTES=()
  # Why a check's knownFailures did or did not apply (R15), on either outcome.
  KNOWN_NOTES=()
}

# attribute_begin -> marks where the current checkout's results start in the
# run.sh arrays.
attribute_begin() {
  ROOT_FAILURES=${#FAILED_OUTPUT[@]}
  ROOT_FAILED_START=${#FAILED_CHECKS[@]}
  ROOT_TIMED_START=${#TIMED_OUT_CHECKS[@]}
  ROOT_UNVERIFIABLE_START=${#UNVERIFIABLE_CHECKS[@]}
  ROOT_NOT_RUN_START=${#NOT_RUN_CHECKS[@]}
  # KNOWN_OK[i]=1: failed check i fails only on its knownFailures (R15).
  KNOWN_OK=()
}

# names_in <base|full|file> <paths file> <output file> [cwd] -> the listed
# paths the output names. The one tokenizer for R4 and R15: the output is
# split into runs of path characters, and each run is looked up: by basename
# in base mode; in full mode as a repo-relative path, once a leading ./ or
# this checkout's root (ROOT_KEY) is dropped, and, for a check run from a
# cwd, also as <cwd>/<run>: a tool there prints paths relative to it
# (src/Foo.php for api/src/Foo.php). A lookup, not a substring scan per path,
# keeps a multi-megabyte test log under a second.
#
# A listed path with a character outside the runs ([id].test.tsx,
# +page.test.ts, a space, a non-ASCII byte) never forms one run, so it is
# found as a substring instead: its basename (base and file mode) or its
# path, less the cwd (full mode), in the output line. Only lines holding a
# run equal to its tail, the part after its last such character, are
# searched, so the scan stays a lookup per run.
#
# File mode (R15) lists every file of the checkout and prints what the output
# names, for attribute.sh to match against knownFailures: each run whose
# basename is a listed file's, made repo-relative as in full mode; each
# listed path found as a substring; and each listed path a dotted name maps
# to (tests.legacy.test_old.OldTest, com.acme.FooTest: its leading parts
# joined with / are a file's path, less its extension, or the end of one, at
# least two parts), the way Python, JVM and other runners name a test.
#
# Every awk here runs under LC_ALL=C: a check's log can hold bytes that are
# not valid in the locale's encoding, and macOS awk then exits 2 ("towc:
# multibyte conversion failure"), which under set -e ended the hook before
# it decided. Bytes are all the matching needs.
names_in() {
  LC_ALL=C MODE="$1" ROOT="$ROOT_KEY/" CWD="${4:-}" awk '
    BEGIN { mode = ENVIRON["MODE"] }
    function emit(key) {
      if (key in hit) return
      hit[key] = 1
      print want[key]
    }
    FILENAME == ARGV[1] {
      key = $0
      if (mode != "full") sub(/.*\//, "", key)
      if (key == "") next
      if (key in want) want[key] = want[key] "\n" $0
      else want[key] = $0
      if (key ~ /[^A-Za-z0-9_.@\/-]/ && !(key in needle)) {
        nd = key
        c = ENVIRON["CWD"]
        if (mode == "full" && c != "" && substr(nd, 1, length(c) + 1) == c "/") nd = substr(nd, length(c) + 2)
        needle[key] = nd
        tl = nd
        sub(/.*[^A-Za-z0-9_.@\/-]/, "", tl)
        if (tl == "") always[key] = 1
        else bytail[tl] = (tl in bytail) ? bytail[tl] SUBSEP key : key
      }
      if (mode == "file") {
        stem = $0
        if (sub(/\.[^.\/]*$/, "", stem)) {
          ns = split(stem, seg, "/")
          s = seg[ns]
          for (j = ns - 1; j >= 1; j--) {
            s = seg[j] "/" s
            suf[s] = (s in suf) ? suf[s] "\n" $0 : $0
          }
        }
      }
      next
    }
    {
      line = $0
      for (k in always) if (!(k in hit) && index(line, needle[k])) emit(k)
      gsub(/[^A-Za-z0-9_.@\/-]+/, " ")
      n = split($0, tok, " ")
      for (i = 1; i <= n; i++) {
        t = tok[i]
        if (t in bytail) {
          m = split(bytail[t], ks, SUBSEP)
          for (j = 1; j <= m; j++) if (!(ks[j] in hit) && index(line, needle[ks[j]])) emit(ks[j])
        }
        if (t in seen) continue
        seen[t] = 1
        sub(/\.+$/, "", t)
        if (mode == "base") {
          sub(/.*\//, "", t)
        } else {
          r = ENVIRON["ROOT"]
          if (substr(t, 1, length(r)) == r) t = substr(t, length(r) + 1)
          while (substr(t, 1, 2) == "./") t = substr(t, 3)
        }
        if (mode == "file") {
          b = t
          sub(/.*\//, "", b)
          if (b in want) {
            if (!(("=" t) in hit)) { hit["=" t] = 1; print t }
          } else if (t ~ /^[^\/]*\.[^\/]*$/) {
            np = split(t, part, ".")
            for (j = np; j >= 2; j--) {
              s = part[1]
              for (q = 2; q <= j; q++) s = s "/" part[q]
              if (s in suf) {
                if (!(("~" s) in hit)) { hit["~" s] = 1; print suf[s] }
                break
              }
            }
          }
          continue
        }
        if (mode != "base" && !(t in want) && ENVIRON["CWD"] != "" && ((ENVIRON["CWD"] "/" t) in want)) t = ENVIRON["CWD"] "/" t
        if (t in want) emit(t)
      }
    }' "$2" "$3"
}

# join_lines <max> -> the first <max> lines of stdin joined with ", ". It
# reads all of stdin: `head` would exit early, and under pipefail the
# writer's SIGPIPE would become the hook's own exit, with no decision printed.
join_lines() {
  LC_ALL=C awk -v max="$1" 'NR <= max { printf "%s%s", (NR > 1 ? ", " : ""), $0 }'
}

# short_list <file> <max> -> "a, b, c and N more"
short_list() {
  local total list
  total=$(grep -c . "$1" || true)
  list=$(join_lines "$2" < "$1")
  if [ "$total" -gt "$2" ]; then
    list="$list and $((total - $2)) more"
  fi
  printf '%s' "$list"
}

# Known failures (R15, #394). A failed check with knownFailures entries (run.sh
# known_failures_verdict) warns instead of blocking when its output
#   1. names a file an entry matches,
#   2. names no file this session wrote (T: by basename, as in rule 2, and
#      by path), and
#   3. names no other file.
# What names a file is names_in's file mode over the checkout's files
# (run.sh checkout_files, listed once per checkout): a run whose last segment
# is a file's basename, a file found as a substring, a dotted name that maps
# to a file. A passing test file a runner lists, a source file in a stack
# trace and a basename alone all count, so condition 3 errs toward blocking.
# What it names is matched to the entries as a repo-relative path, as rule 3
# matches F, and for a check with a cwd also as <cwd>/<path>.

# known_failure <failed index> <T file> -> 0 when the check's failure is a
# known one. Sets KNOWN_NOTE to why it applied or did not ("" when the check
# has no entries).
known_failure() {
  local i="$1" tfile="$2" entries="${FAILED_KNOWN[$1]:-}" cwd="${FAILED_CWDS[$1]:-}"
  local name="${FAILED_CHECKS[$1]}" named tok re glob reason hit hits="" outside="" own="" nout=0
  KNOWN_NOTE=""
  [ -n "$entries" ] || return 1
  if [ -s "$tfile" ]; then
    own=$(names_in base "$tfile" "${FAILED_LOGS[$i]}" | join_lines 5)
  fi
  checkout_files
  named=$(mktemp "${TMPDIR:-/tmp}/.myspec-known.XXXXXX")
  names_in file "$CHECKOUT_FILES" "${FAILED_LOGS[$i]}" "$cwd" > "$named"
  # A file of T named by its path or a dotted name, not its basename.
  if [ -z "$own" ] && [ -s "$tfile" ]; then
    own=$(LC_ALL=C awk -v cwd="$cwd" 'FILENAME == ARGV[1] { t[$0] = 1; next } ($0 in t) || (cwd != "" && ((cwd "/" $0) in t)) { print }' "$tfile" "$named" | join_lines 5)
  fi
  if [ -n "$own" ]; then
    rm -f "$named"
    KNOWN_NOTE="$name: knownFailures not applied, it names files this session wrote: $own."
    return 1
  fi
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    hit=0
    while IFS=$'\t' read -r re glob reason; do
      if [[ "$tok" =~ $re ]] || { [ -n "$cwd" ] && [[ "$cwd/$tok" =~ $re ]]; }; then
        hit=1
        case $'\n'"$hits"$'\n' in
          *$'\n'"$glob ($reason)"$'\n'*) ;;
          *) hits="${hits:+$hits$'\n'}$glob ($reason)" ;;
        esac
      fi
    done <<< "$entries"
    if [ "$hit" -eq 0 ]; then
      case ", $outside, " in
        *", $tok, "*) continue ;;
      esac
      outside="${outside:+$outside, }$tok"
      nout=$((nout + 1))
      # One file outside the entries decides it; five name it well enough.
      [ "$nout" -lt 5 ] || break
    fi
  done < "$named"
  rm -f "$named"
  if [ -n "$outside" ]; then
    KNOWN_NOTE="$name: knownFailures not applied, it also names files no entry matches: $outside."
    return 1
  fi
  if [ -z "$hits" ]; then
    KNOWN_NOTE="$name: knownFailures not applied, it names no file an entry matches."
    return 1
  fi
  KNOWN_NOTE="$name fails only on its knownFailures: $(printf '%s\n' "$hits" | LC_ALL=C awk '{ printf "%s%s", (NR > 1 ? "; " : ""), $0 }')."
  return 0
}

# attribute_failures: for the checks of the checkout at ROOT_KEY (from index
# ROOT_FAILED_START on, T from MYSPEC_SESSION_FILES), sets ATTRIBUTION (a paragraph for the report, empty
# when every uncommitted change there is this session's) and ATTRIBUTION_WARN=1
# when its failures should warn instead of block.
attribute_failures() {
  local tfile ffile i own foreign where lines="" unknown=0 owned=0
  ATTRIBUTION=""
  ATTRIBUTION_WARN=0
  tfile=$(mktemp "${TMPDIR:-/tmp}/.myspec-attr.XXXXXX")
  ffile=$(mktemp "${TMPDIR:-/tmp}/.myspec-attr.XXXXXX")
  # T is MYSPEC_SESSION_FILES, which arm_root read once for this checkout:
  # reading the state file again here would parse it twice per failing root.
  [ -z "${MYSPEC_SESSION_FILES:-}" ] || printf '%s\n' "$MYSPEC_SESSION_FILES" > "$tfile"
  # .claude/state/ is per-checkout hook state, not anyone's work. At most 1000
  # paths take part: past that, a failure matches nothing, which blocks.
  changed_files | grep -v '^\.claude/state/' | sort -u | grep -vxF -f "$tfile" | LC_ALL=C awk 'NR <= 1000' > "$ffile" || true
  if [ ! -s "$ffile" ]; then
    rm -f "$tfile" "$ffile"
    return 0
  fi
  for ((i = ROOT_FAILED_START; i < ${#FAILED_CHECKS[@]}; i++)); do
    # A check that fails only on its knownFailures is settled already (R15).
    [ -z "${KNOWN_OK[$i]:-}" ] || continue
    own=$(names_in base "$tfile" "${FAILED_LOGS[$i]}" | join_lines 5)
    if [ -n "$own" ]; then
      owned=1
      lines="$lines"$'\n'"- ${FAILED_CHECKS[$i]} names files this session wrote: $own"
      continue
    fi
    foreign=$(names_in full "$ffile" "${FAILED_LOGS[$i]}" "${FAILED_CWDS[$i]:-}" | join_lines 5)
    if [ -n "$foreign" ]; then
      lines="$lines"$'\n'"- ${FAILED_CHECKS[$i]} names only files changed outside this session: $foreign"
    else
      unknown=1
      lines="$lines"$'\n'"- ${FAILED_CHECKS[$i]} names none of the changed files"
    fi
  done
  if [ "$owned" -eq 0 ] && [ "$unknown" -eq 0 ] && [ ${#TIMED_OUT_CHECKS[@]} -eq "$ROOT_TIMED_START" ] \
      && [ ${#UNVERIFIABLE_CHECKS[@]} -eq "$ROOT_UNVERIFIABLE_START" ] \
      && [ ${#NOT_RUN_CHECKS[@]} -eq "$ROOT_NOT_RUN_START" ]; then
    ATTRIBUTION_WARN=1
  fi
  where="This checkout"
  [ "$ROOT_KEY" = "$ORIG_ROOT" ] || where="The checkout at $ROOT_KEY"
  ATTRIBUTION="$where has uncommitted changes this session did not write ($(short_list "$ffile" 10)), so a failure may not be yours.$lines"
  rm -f "$tfile" "$ffile"
}

# attribute_root -> after the current checkout's checks ran: nothing when
# they all passed (a check the budget left unrun did not pass, R13); a warning during a live feature-implement run (R6) or when
# attribution clears every failure (R4); otherwise BLOCKING_FAILURE=1, with
# the attribution paragraph when there is one.
attribute_root() {
  [ "${#FAILED_OUTPUT[@]}" -gt "$ROOT_FAILURES" ] || [ "${#NOT_RUN_CHECKS[@]}" -gt "$ROOT_NOT_RUN_START" ] || return 0
  if [ "$IMPLEMENT_ACTIVE" -eq 1 ]; then
    # Nothing failed when the budget only left checks unrun: say that, not
    # "failing", or the controller reads its tree as red.
    local what="Failing"
    [ "${#FAILED_OUTPUT[@]}" -gt "$ROOT_FAILURES" ] || what="Checks not run (gate budget)"
    WARN_NOTES+=("$what${ROOT_LABEL} during feature-implement orchestration; not blocking (session-event.sh implement start). The final verification step still gates.")
    return 0
  fi
  local i tfile rest=0 known_any=0 known_warn=0 what="names only files changed outside this session"
  ATTRIBUTION=""
  ATTRIBUTION_WARN=0
  if [ "${#FAILED_CHECKS[@]}" -gt "$ROOT_FAILED_START" ]; then
    # Known failures first (R15): they apply whether or not another session
    # left changes here.
    tfile=$(mktemp "${TMPDIR:-/tmp}/.myspec-attr.XXXXXX")
    [ -z "${MYSPEC_SESSION_FILES:-}" ] || printf '%s\n' "$MYSPEC_SESSION_FILES" > "$tfile"
    # List the checkout's files again, once for this checkout: its checks
    # may have added some since run.sh listed them.
    CHECKOUT_FILES_ROOT=""
    for ((i = ROOT_FAILED_START; i < ${#FAILED_CHECKS[@]}; i++)); do
      if known_failure "$i" "$tfile"; then
        KNOWN_OK[i]=1
        known_any=1
      else
        rest=1
      fi
      [ -z "$KNOWN_NOTE" ] || KNOWN_NOTES+=("$KNOWN_NOTE")
    done
    rm -f "$tfile"
    if [ "$rest" -eq 1 ]; then
      attribute_failures
    elif [ ${#TIMED_OUT_CHECKS[@]} -eq "$ROOT_TIMED_START" ] \
        && [ ${#UNVERIFIABLE_CHECKS[@]} -eq "$ROOT_UNVERIFIABLE_START" ] \
        && [ ${#NOT_RUN_CHECKS[@]} -eq "$ROOT_NOT_RUN_START" ]; then
      # Like rule 3, a timeout, a refusal or an unrun check is never
      # downgraded.
      known_warn=1
    fi
  fi
  if [ "$ATTRIBUTION_WARN" -eq 1 ]; then
    # The failures are real, but they name only files another session left
    # uncommitted (or are known failures, R15).
    [ "$known_any" -eq 0 ] || what="$what or is a known failure"
    WARN_NOTES+=("Not blocking: every failure${ROOT_LABEL} $what. $ATTRIBUTION"$'\n'"A worktree per session keeps each session's gate to its own changes.")
  elif [ "$known_warn" -eq 1 ]; then
    WARN_NOTES+=("Not blocking: every failure${ROOT_LABEL} is one its check lists under knownFailures in .claude/verification.json. Remove an entry once its file passes.")
  else
    BLOCKING_FAILURE=1
    if [ -n "$ATTRIBUTION" ]; then
      BLOCK_NOTES+=("$ATTRIBUTION")
    fi
  fi
}
