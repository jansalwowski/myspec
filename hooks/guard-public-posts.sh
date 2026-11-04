#!/usr/bin/env bash
# guard-public-posts.sh
# PreToolUse hook (Bash matcher) — stops a `gh` post that would copy this
# project's private identifiers into a different, public GitHub repository
# (#380). An agent working inside a private project files framework bugs
# upstream (doctor findings, a script that misclassified something) and pastes
# the repo name, branch names, ticket keys and commit SHAs it was looking at.
# GitHub keeps issue and comment edit history, so a scrub after posting does
# not undo the leak; the check has to run before the network call.
#
# WHAT IS A POST: at command position (lib/command-scan.sh, so a gh verb inside
# a quoted body or a heredoc is not one), past keywords, assignments and the
# launchers env, command, exec, sudo, nohup, time, nice and xargs:
# `gh issue create|comment|edit|close|reopen` and `gh pr create|comment|edit|
# close|reopen|review|merge`, every subcommand with a text flag, whose flags
# are read per subcommand (flag_kind), and `gh api` with a POST, PATCH or PUT
# (or a field, which makes gh POST) to `repos/<o>/<r>/issues…` or
# `repos/<o>/<r>/pulls…`. Not seen: a `gh api graphql` mutation, a gh run
# inside `bash -c`, and the words after an `xargs -I{}` (the scanner splits
# at braces).
#
# WHERE IT GOES: the URL operand (`gh issue comment https://<host>/<o>/<r>/
# issues/1`), else `-R`/`--repo`, else the `gh api` endpoint, else GH_REPO (an
# assignment on the segment, then the last `export GH_REPO=` or bare
# assignment before it, `unset` clearing it, then the hook's environment),
# else the repository gh resolves in the directory the segment runs in (after
# any `cd` before it): the remote `gh repo set-default` recorded, else
# `upstream`, `github`, `origin`. A post to the project's own `origin` is
# never checked: its identifiers are already there.
#
# WHAT IS SCANNED: the text the post sends, where it is statically visible:
# `--title`, `--body`, `--comment`, the files of `--body-file`/`-F` (and
# `$(cat <file>)` inside a body), `gh api` field values and `-F key=@file` /
# `--input` files, and every heredoc body in the command. A body held in a
# shell variable or piped in from another command is not seen.
#
# WHAT IS A HIT, all derived from the project the session works in (the
# payload cwd's checkout), so nothing here names one stack or one tracker:
#   - its origin owner and repo name, and `owner/repo` (case-insensitive,
#     whole word; an owner or name the target shares is skipped, and so is a
#     generic repo name such as `app` or `api`)
#   - its local and remote-tracking branch names, skipping the default branch,
#     generic names (main, master, develop, dev, staging, release, …), names
#     under four characters and single plain words under six
#   - hex strings of 7 to 40 characters that name a commit in it
#     (`git cat-file --batch-check`)
#   - a ticket key such as ABC-123 whose prefix the project's own tracker
#     uses: one in a branch name, or leading one of its last 300 commit
#     subjects. A generic ABC-123 shape matches GPL-3, PHP-8 and GH-12 too.
#   - a Claude Code session link, a home directory path (/Users/<name>,
#     /home/<name>), an email address and a credential-shaped token: shapes
#     scripts/triage/redaction-check.mjs also checks after the fact on the
#     myspec repo itself (maintainer tooling, not shipped; nothing is shared)
#   - each entry of the setting hooks.guardPublicPosts.privateIdentifiers:
#     a literal (case-insensitive, whole word) or, written `/…/`, an extended
#     regex (codenames, another tracker's ticket prefix)
# When the target is one of the project's own remotes (the project is a fork
# of it), branch names and commits that remote already has are public there
# and skipped. When the project's own origin is public, its owner and name,
# the branches origin has and the commits it contains are skipped too; a
# local-only branch or an unpushed commit still counts.
#
# VISIBILITY: asked only when something matched, with one
# `gh api repos/<o>/<r>` call per repository and session (each target, then
# origin when a project-derived name matched), cached as a
# `visibility` event in the session-state file (lib/session-event.sh; only in
# a checkout that has one, a myspec project). Private and internal targets are
# allowed. When gh cannot answer (offline, not logged in, rate-limited), the
# target is treated as public: a leak cannot be taken back and a false block
# costs one re-run with the override, so the unknown case errs toward the
# check. Infrastructure alone never blocks: a post with no match is allowed
# whatever gh says, and without gh on PATH the post cannot run at all.
#
# Escape hatch: MYSPEC_ALLOW_PUBLIC_POST=1 as an assignment prefix of the gh
# command itself (`MYSPEC_ALLOW_PUBLIC_POST=1 gh …`, `env MYSPEC_…=1 gh …`).
# Text anywhere else, a body that quotes it or an earlier segment, does not
# count, and neither does an export: the pass is per post, so a second post
# in the same command is still checked. Stricter than guard-worktree-
# context.sh's MYSPEC_ALLOW_MAIN_CHECKOUT, which matches anywhere, because a
# post body is where a quoted override would sit. Advertised in the block
# message: a match can be a public name that happens to equal a private one,
# and only the agent reading the text can tell.
#
# COST: the hook runs on every Bash call. The payload is read with a builtin
# and matched with [[ =~ ]], so a call that is not a gh issue, pr or api
# command exits before any process starts.
#
# Output contract: a block prints the PreToolUse deny form (pretool_deny in
# lib/hook-core.sh). An allowed command prints NOTHING and exits 0.
# Tests: hooks/tests/guard-public-posts.test.sh (plugin repo only).
# bash 3.2 compatible (macOS /bin/bash).

set -euo pipefail

PAYLOAD=""
IFS= read -r -d '' PAYLOAD || true
FAST_RE='gh[[:space:]]+(issue|pr|api)[[:space:]]'
[[ $PAYLOAD =~ $FAST_RE ]] || exit 0

command -v jq >/dev/null 2>&1 || exit 0
# The same preamble as the other PreToolUse hooks: without hook-core.sh the
# gate is not running, and approving in silence would hide that. Only a gh
# post reaches this line, so the deny costs no other command.
HOOK_CORE="${CLAUDE_PLUGIN_ROOT:-/nonexistent}/lib/hook-core.sh"
if [ ! -f "$HOOK_CORE" ]; then
  LIB_MISSING="myspec lib missing: hook-core.sh not found under \${CLAUDE_PLUGIN_ROOT}/lib (CLAUDE_PLUGIN_ROOT is ${CLAUDE_PLUGIN_ROOT:-unset}). The hook did not run from the plugin's hooks.json; a copy wired in .claude/settings.json is retired by /myspec:update."
  printf '%s\n' "$LIB_MISSING" >&2
  jq -nc --arg r "$LIB_MISSING" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
fi
# hook-core.sh present but a lib this hook sources missing: name it, as
# no-absolute-paths.sh does, rather than approve in silence.
LIB_MISSING=""
for f in command-scan.sh session-event.sh; do
  [ -f "$(dirname "$HOOK_CORE")/$f" ] || LIB_MISSING="${LIB_MISSING:+$LIB_MISSING, }$f"
done
if [ -n "$LIB_MISSING" ]; then
  LIB_MISSING="myspec lib missing: $LIB_MISSING not found under \${CLAUDE_PLUGIN_ROOT}/lib (${CLAUDE_PLUGIN_ROOT}), so guard-public-posts.sh checked nothing. The hook runs from the plugin's hooks.json since 3.0; a copy wired in .claude/settings.json is retired by /myspec:update."
  printf '%s\n' "$LIB_MISSING" >&2
  jq -nc --arg r "$LIB_MISSING" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
fi
# shellcheck source=lib/hook-core.sh
. "$HOOK_CORE"
# shellcheck source=lib/session-event.sh
. "$HOOK_LIB/session-event.sh"
# shellcheck source=lib/command-scan.sh
. "$HOOK_LIB/command-scan.sh"

payload_parse "$PAYLOAD" COMMAND=.tool_input.command SESSION_ID=.session_id CWDS="$HOOK_CWDS"
[ -n "$COMMAND" ] || exit 0
command -v gh >/dev/null 2>&1 || exit 0

START_DIR=$(first_dir "$CWDS") || START_DIR="$PWD"
P_ROOT=$(hook_repo_root "$CWDS") || P_ROOT=""

# repo_key <remote URL | host/o/r | o/r | https://host/o/r/...> -> host/o/r,
# lowercase, without .git. A bare o/r is on GH_HOST, else github.com.
repo_key() {
  local u="$1" host path owner rest repo
  case "$u" in
    *://*) u="${u#*://}"; u="${u#*@}"; host="${u%%/*}"; path="${u#*/}" ;;
    *@*:*) u="${u#*@}"; host="${u%%:*}"; path="${u#*:}" ;;
    */*/*) host="${u%%/*}"; path="${u#*/}" ;;
    */*) host="${GH_HOST:-github.com}"; path="$u" ;;
    *) return 1 ;;
  esac
  host="${host%%:*}"
  owner="${path%%/*}"
  rest="${path#*/}"
  repo="${rest%%/*}"
  repo="${repo%.git}"
  [ -n "$host" ] && [ -n "$owner" ] && [ -n "$repo" ] && [ "$rest" != "$path" ] || return 1
  printf '%s/%s/%s\n' "$host" "$owner" "$repo" | tr '[:upper:]' '[:lower:]'
}

# dir_target <dir> -> repo_key of the repository gh posts to from <dir>.
dir_target() {
  local d="$1" name="" val url
  while read -r name val; do
    name="${name#remote.}"
    name="${name%.gh-resolved}"
    case "$val" in
      base|'') break ;;
      *) repo_key "$val"; return ;;
    esac
  done < <(git -C "$d" config --get-regexp '^remote\..*\.gh-resolved$' 2>/dev/null || true)
  if [ -z "$name" ]; then
    for name in upstream github origin; do
      git -C "$d" remote get-url "$name" >/dev/null 2>&1 && break
      name=""
    done
  fi
  [ -n "$name" ] || return 1
  url=$(git -C "$d" remote get-url "$name" 2>/dev/null) || return 1
  repo_key "$url"
}

# flag_kind <group> <verb> <flag> -> FK: text (its value is posted), file
# (a file whose content is posted), value (takes a value that is not posted)
# or bool. Per subcommand, from `gh <group> <verb> --help`: `-c` is a comment
# on close and reopen but a boolean on `pr review`, `-m` a milestone on
# create but a boolean on `pr merge`.
flag_kind() {
  FK=bool
  case "$3" in -R|--repo) FK=value; return 0 ;; esac
  case "$1 $2" in
    "issue create")
      case "$3" in
        -t|--title|-b|--body) FK=text ;;
        -F|--body-file) FK="file" ;;
        -a|--assignee|--attach|--blocked-by|--blocking|-l|--label|-m|--milestone|--parent|-p|--project|--recover|-T|--template|--type) FK=value ;;
      esac ;;
    "issue comment"|"pr comment")
      case "$3" in -b|--body) FK=text ;; -F|--body-file) FK="file" ;; --attach) FK=value ;; esac ;;
    "issue edit"|"pr edit")
      case "$3" in
        -t|--title|-b|--body) FK=text ;;
        -F|--body-file) FK="file" ;;
        --add-*|--remove-*|--attach|-m|--milestone|--parent|--type|-B|--base) FK=value ;;
      esac ;;
    "issue close")
      case "$3" in -c|--comment) FK=text ;; --duplicate-of|-r|--reason) FK=value ;; esac ;;
    "issue reopen"|"pr close"|"pr reopen")
      case "$3" in -c|--comment) FK=text ;; esac ;;
    "pr create")
      case "$3" in
        -t|--title|-b|--body) FK=text ;;
        -F|--body-file) FK="file" ;;
        -a|--assignee|--attach|-B|--base|-H|--head|-l|--label|-m|--milestone|-p|--project|--recover|-r|--reviewer|-T|--template) FK=value ;;
      esac ;;
    "pr review")
      case "$3" in -b|--body) FK=text ;; -F|--body-file) FK="file" ;; esac ;;
    "pr merge")
      case "$3" in
        -b|--body|-t|--subject|-A|--author-email) FK=text ;;
        -F|--body-file) FK="file" ;;
        --match-head-commit) FK=value ;;
      esac ;;
    "api "*)
      case "$3" in
        -X|--method) FK=method ;;
        -f|--raw-field) FK=rawfield ;;
        -F|--field) FK=field ;;
        --input) FK="file" ;;
        --hostname) FK=hostname ;;
        -H|--header|-q|--jq|-t|--template|-p|--preview|--cache) FK=value ;;
      esac ;;
  esac
}

# parse_gh <word>... (keep-mode words after `gh`) -> G_POST=1 for a post,
# G_REPO (where it says it goes, if it does), G_TEXT (its inline text) and
# G_FILES (the files it sends, one per line). A flag's value may follow it,
# be attached with `=` (`--body=x`), or be glued to a short flag (`-bx`,
# `-fbody=x`, `-XPOST`).
parse_gh() {
  local n=$# i=0 w v name group="" verb="" method="" endpoint="" fields=0 host="" url_repo="" re attached
  local -a a=("$@")
  G_POST=0 G_REPO="" G_TEXT="" G_FILES=""
  [ "$n" -gt 0 ] || return 0
  decode_word_to group "${a[0]}"
  case "$group" in issue|pr) ;; api) verb=api ;; *) return 0 ;; esac
  i=1
  # The verb: the first operand, past any -R before it.
  while [ -z "$verb" ] && [ "$i" -lt "$n" ]; do
    decode_word_to w "${a[i]}"
    case "$w" in
      -R|--repo) [ $((i + 1)) -ge "$n" ] || decode_word_to G_REPO "${a[i + 1]}"; i=$((i + 2)) ;;
      --repo=*) G_REPO="${w#*=}"; i=$((i + 1)) ;;
      -*) i=$((i + 1)) ;;
      *) verb="$w"; i=$((i + 1)) ;;
    esac
  done
  while [ "$i" -lt "$n" ]; do
    decode_word_to w "${a[i]}"
    attached=0 name="$w" v=""
    case "$w" in
      --*=*) name="${w%%=*}"; v="${w#*=}"; attached=1 ;;
      --*) ;;
      -?)  ;;
      -*)
        flag_kind "$group" "$verb" "${w:0:2}"
        if [ "$FK" != bool ]; then name="${w:0:2}"; v="${w:2}"; attached=1; fi ;;
    esac
    case "$name" in
      -*) flag_kind "$group" "$verb" "$name" ;;
      *)
        if [ "$group" = api ]; then
          [ -n "$endpoint" ] || endpoint="$w"
        else
          re='^https?://[^/]+/[^/]+/[^/]+/(issues|pull)/[0-9]+'
          [[ $w =~ $re ]] && url_repo="$w"
        fi
        i=$((i + 1)); continue ;;
    esac
    if [ "$FK" = bool ]; then i=$((i + 1)); continue; fi
    if [ "$attached" = 0 ]; then
      [ $((i + 1)) -ge "$n" ] || decode_word_to v "${a[i + 1]}"
      i=$((i + 2))
    else
      i=$((i + 1))
    fi
    case "$name:$FK" in
      -R:*|--repo:*) G_REPO="$v" ;;
      *:text) G_TEXT="$G_TEXT$v"$'\n' ;;
      *:file) fields=1; G_FILES="$G_FILES$v"$'\n' ;;
      *:method) method="$v" ;;
      *:hostname) host="$v" ;;
      *:rawfield) fields=1; G_TEXT="$G_TEXT${v#*=}"$'\n' ;;
      *:field)
        fields=1
        v="${v#*=}"
        case "$v" in
          @*) G_FILES="$G_FILES${v#@}"$'\n' ;;
          *) G_TEXT="$G_TEXT$v"$'\n' ;;
        esac ;;
    esac
  done
  if [ "$group" = api ]; then
    method=$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')
    [ -n "$method" ] || { [ "$fields" = 1 ] && method=POST || method=GET; }
    case "$method" in POST|PATCH|PUT) ;; *) return 0 ;; esac
    re='^/?repos/([^/]+)/([^/?]+)/(issues|pulls)([/?]|$)'
    [[ $endpoint =~ $re ]] || return 0
    G_POST=1
    case "${BASH_REMATCH[1]}${BASH_REMATCH[2]}" in
      *'{'*) G_REPO="" ;;
      *) G_REPO="${host:+$host/}${BASH_REMATCH[1]}/${BASH_REMATCH[2]}" ;;
    esac
    return 0
  fi
  case "$verb" in create|comment|edit|review|close|reopen|merge) G_POST=1 ;; *) return 0 ;; esac
  [ -z "$url_repo" ] || G_REPO="$url_repo"
}

ORIGIN_KEY=""
if [ -n "$P_ROOT" ]; then
  ORIGIN_KEY=$(repo_key "$(git -C "$P_ROOT" remote get-url origin 2>/dev/null || true)" 2>/dev/null || true)
fi

# Walk the segments: track `cd` and GH_REPO, collect each post that leaves
# this project. Before a command name come keywords, assignments (a
# GH_REPO=, or the override MYSPEC_ALLOW_PUBLIC_POST=1, which counts only
# here, on the post's own segment) and launchers (env, command, exec, sudo,
# nohup, time, nice, xargs) with their options.
TARGETS=""
TEXT=""
FILES=""
DIR="$START_DIR"
SHELL_GH_REPO="${GH_REPO:-}"
w="" w1=""
CAT_RE='\$\((cat[[:space:]]+|<[[:space:]]*)([^)[:space:]]+)\)'
SEGMENTS=$(printf '%s\n' "$COMMAND" | sanitize_command keep | split_segments)
while IFS=$'\t' read -r _sep seg; do
  W=()
  read -r -a W <<< "$seg" || true
  n=${#W[@]}
  i=0 launcher="" seg_repo="" seg_override=0 seg_assign_repo=""
  while [ "$i" -lt "$n" ]; do
    decode_word_to w "${W[i]}"
    case "$w" in
      then|do|else|'!'|'{') i=$((i + 1)); continue ;;
      env|command|exec|sudo|nohup|time|nice|xargs) launcher="$w"; i=$((i + 1)); continue ;;
    esac
    if [ -n "$launcher" ]; then
      case "$launcher:$w" in
        env:-u|env:-C|env:-S|nice:-n|xargs:-I|xargs:-n|xargs:-P|xargs:-L|xargs:-d|xargs:-s|xargs:-E|sudo:-u|sudo:-g)
          i=$((i + 2)); continue ;;
        *:-*) i=$((i + 1)); continue ;;
      esac
    fi
    if [[ $w =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      case "$w" in
        GH_REPO=*) seg_assign_repo="${w#GH_REPO=}" ;;
        MYSPEC_ALLOW_PUBLIC_POST=1) seg_override=1 ;;
      esac
      i=$((i + 1)); continue
    fi
    break
  done
  if [ "$i" -ge "$n" ]; then
    # Assignments alone set a shell variable; gh sees it once exported, and
    # a bare one may already be. Count it.
    [ -z "$seg_assign_repo" ] || SHELL_GH_REPO="$seg_assign_repo"
    continue
  fi
  seg_repo="$seg_assign_repo"
  case "$w" in
    cd)
      if [ $((i + 1)) -lt "$n" ]; then
        decode_word_to w1 "${W[i + 1]}"
        case "$w1" in /*) cand="$w1" ;; *) cand="$DIR/$w1" ;; esac
        [ ! -d "$cand" ] || DIR="$cand"
      fi
      continue ;;
    export|unset)
      j=$((i + 1))
      while [ "$j" -lt "$n" ]; do
        decode_word_to w1 "${W[j]}"
        case "$w:$w1" in
          export:GH_REPO=*) SHELL_GH_REPO="${w1#GH_REPO=}" ;;
          unset:GH_REPO) SHELL_GH_REPO="" ;;
        esac
        j=$((j + 1))
      done
      continue ;;
    gh|*/gh) ;;
    *) continue ;;
  esac
  [ "$seg_override" = 0 ] || continue
  [ $((i + 1)) -lt "$n" ] || continue
  parse_gh "${W[@]:$((i + 1))}"
  [ "$G_POST" = 1 ] || continue
  target=""
  if [ -n "$G_REPO" ]; then
    target=$(repo_key "$G_REPO" 2>/dev/null || true)
  elif [ -n "$seg_repo" ]; then
    target=$(repo_key "$seg_repo" 2>/dev/null || true)
  elif [ -n "$SHELL_GH_REPO" ]; then
    target=$(repo_key "$SHELL_GH_REPO" 2>/dev/null || true)
  else
    target=$(dir_target "$DIR" 2>/dev/null || true)
  fi
  [ -n "$target" ] || continue
  [ "$target" != "$ORIGIN_KEY" ] || continue
  case $'\n'"$TARGETS" in *$'\n'"$target"$'\n'*) ;; *) TARGETS="$TARGETS$target"$'\n' ;; esac
  TEXT="$TEXT$G_TEXT"
  # `$(cat <file>)` / `$(< <file>)` inside an inline body, read from the
  # directory this segment runs in.
  rest="$G_TEXT"
  while [[ $rest =~ $CAT_RE ]]; do
    f="${BASH_REMATCH[2]}"
    rest="${rest#*"${BASH_REMATCH[0]}"}"
    f="${f#[\'\"]}"; f="${f%[\'\"]}"
    G_FILES="$G_FILES$f"$'\n'
  done
  while IFS= read -r f; do
    if [ -z "$f" ] || [ "$f" = - ]; then continue; fi
    case "$f" in /*) ;; *) f="$DIR/$f" ;; esac
    FILES="$FILES$f"$'\n'
  done <<< "$G_FILES"
done <<< "$SEGMENTS"
[ -n "$TARGETS" ] || exit 0

SCAN=$(mktemp "${TMPDIR:-/tmp}/.myspec-post.XXXXXX") || exit 0
WORK=$(mktemp -d "${TMPDIR:-/tmp}/.myspec-post-d.XXXXXX") || { rm -f "$SCAN"; exit 0; }
trap 'rm -rf "$SCAN" "$WORK"' EXIT
printf '%s\n' "$TEXT" > "$SCAN"
while IFS= read -r f; do
  if [ -z "$f" ] || [ ! -f "$f" ] || [ ! -r "$f" ]; then continue; fi
  head -c 1048576 "$f" >> "$SCAN" 2>/dev/null || true
  printf '\n' >> "$SCAN"
done <<< "$FILES"
# Heredoc bodies, read from the raw command: lib/command-scan.sh blanks them,
# and a body inside `--body "$(cat <<'EOF' … EOF)"` is a heredoc too.
printf '%s\n' "$COMMAND" | awk '
  { line[NR] = $0 }
  END {
    i = 1
    while (i <= NR) {
      s = line[i]; n = 0
      while ((p = index(s, "<<")) > 0) {
        s = substr(s, p + 2)
        if (substr(s, 1, 1) == "<") { s = substr(s, 2); continue }
        if (substr(s, 1, 1) == "-") s = substr(s, 2)
        sub(/^[ \t]+/, "", s)
        q = substr(s, 1, 1)
        if (q == "\047" || q == "\"" || q == "\\") s = substr(s, 2)
        if (match(s, /^[A-Za-z0-9_]+/)) { term[++n] = substr(s, 1, RLENGTH); s = substr(s, RLENGTH + 1) }
      }
      i++
      for (k = 1; k <= n; k++) {
        while (i <= NR) {
          t = line[i]; sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
          i++
          if (t == term[k]) break
          print line[i - 1]
        }
      }
    }
  }' >> "$SCAN"

HITS="$WORK/hits"
: > "$HITS"
hit() { printf '%s\t%s\n' "$1" "$2" >> "$HITS"; }

# --- shapes (no project needed) ----------------------------------------------
while IFS= read -r m; do [ -n "$m" ] && hit session "$m"; done \
  < <(grep -oE 'claude\.ai/code/session_[A-Za-z0-9_-]+' "$SCAN" 2>/dev/null | sort -u || true)
while IFS= read -r m; do
  [ -n "$m" ] || continue
  case "$(printf '%s' "${m#/*/}" | tr '[:upper:]' '[:lower:]')" in alice|bob|me|runner|user|you|username|name) continue ;; esac
  hit home "$m"
done < <(grep -oE '/(Users|home)/[A-Za-z0-9._-]+' "$SCAN" 2>/dev/null | sort -u || true)
while IFS= read -r m; do
  [ -n "$m" ] || continue
  case "$(printf '%s' "$m" | tr '[:upper:]' '[:lower:]')" in
    *@*noreply.*|*@example.com|*@example.org|*@anthropic.com|git@*) continue ;;
  esac
  hit email "$m"
done < <(grep -oE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$SCAN" 2>/dev/null | sort -u || true)
while IFS= read -r m; do [ -n "$m" ] && hit credential "$m"; done \
  < <(grep -oE 'ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|xox[abp]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}' "$SCAN" 2>/dev/null | sort -u || true)

# --- the project's own identifiers --------------------------------------------
REFS=""
if [ -n "$P_ROOT" ]; then
  # A target that is one of this project's remotes (it is a fork): what that
  # remote already has is public there.
  FORK_REMOTE=""
  while read -r rname rurl _; do
    [ -n "$rname" ] || continue
    k=$(repo_key "$rurl" 2>/dev/null || true)
    [ -n "$k" ] || continue
    case $'\n'"$TARGETS" in *$'\n'"$k"$'\n'*) FORK_REMOTE="$rname"; break ;; esac
  done < <(git -C "$P_ROOT" remote -v 2>/dev/null | awk '$3 == "(push)" || $3 == "(fetch)"' | sort -u || true)

  LIT="$WORK/literal"      # kind<TAB>value, matched case-insensitively
  BR="$WORK/branches"      # branch names, matched as written
  : > "$LIT"
  : > "$BR"
  if [ -n "$ORIGIN_KEY" ]; then
    o_rest="${ORIGIN_KEY#*/}"
    o_owner="${o_rest%%/*}"
    o_repo="${o_rest#*/}"
    t_owners=$(printf '%s' "$TARGETS" | awk -F/ '{print $2}')
    t_repos=$(printf '%s' "$TARGETS" | awk -F/ '{print $3}')
    printf 'repo\t%s/%s\n' "$o_owner" "$o_repo" >> "$LIT"
    if [ "${#o_owner}" -ge 3 ] && ! grep -qxF -- "$o_owner" <<< "$t_owners"; then
      printf 'owner\t%s\n' "$o_owner" >> "$LIT"
    fi
    case "$o_repo" in
      app|apps|api|web|www|site|docs|server|client|frontend|backend|core|service|services|monorepo|infra|platform|website|mobile) ;;
      *)
        if [ "${#o_repo}" -ge 4 ] && ! grep -qxF -- "$o_repo" <<< "$t_repos"; then
          printf 'repo\t%s\n' "$o_repo" >> "$LIT"
        fi ;;
    esac
  fi
  if read_setting hooks.guardPublicPosts.privateIdentifiers "$P_ROOT"; then
    [ -z "$SETTING_NOTES" ] || printf '%s\n' "$SETTING_NOTES" | sed 's/^/myspec-config: /' >&2
    while IFS= read -r ident; do
      [ -n "$ident" ] || continue
      case "$ident" in
        /?*/)
          re="${ident#/}"; re="${re%/}"
          while IFS= read -r m; do [ -n "$m" ] && hit configured "$m"; done \
            < <(grep -oE -- "$re" "$SCAN" 2>/dev/null | sort -u || true) ;;
        *) printf 'configured\t%s\n' "$ident" >> "$LIT" ;;
      esac
    done < <(printf '%s' "$SETTING" | jq -r 'if type == "array" then .[] | strings else empty end' 2>/dev/null || true)
  fi

  DEFAULT_BRANCH=$(git -C "$P_ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  DEFAULT_BRANCH="${DEFAULT_BRANCH#origin/}"
  REFS=$(git -C "$P_ROOT" for-each-ref --format='%(refname)' refs/heads refs/remotes 2>/dev/null || true)
  PUBLIC_BRANCHES=""
  if [ -n "$FORK_REMOTE" ]; then
    PUBLIC_BRANCHES=$(printf '%s\n' "$REFS" | sed -n "s#^refs/remotes/$FORK_REMOTE/##p")
  fi
  while IFS= read -r ref; do
    case "$ref" in
      refs/heads/*) b="${ref#refs/heads/}" ;;
      refs/remotes/*) b="${ref#refs/remotes/}"; [ "${b%%/*}" != "$FORK_REMOTE" ] || continue; b="${b#*/}" ;;
      *) continue ;;
    esac
    if [ "${#b}" -lt 4 ] || [ "$b" = "$DEFAULT_BRANCH" ]; then continue; fi
    case "$b" in
      HEAD|main|master|develop|development|devel|trunk|staging|stage|production|prod|release|releases|next|stable|beta|alpha|canary|preview|gh-pages|test|testing|integration|hotfix|bugfix|feature|default|backup) continue ;;
    esac
    [[ $b =~ ^[A-Za-z]+$ ]] && [ "${#b}" -lt 6 ] && continue
    [ -z "$PUBLIC_BRANCHES" ] || ! grep -qxF -- "$b" <<< "$PUBLIC_BRANCHES" || continue
    printf '%s\n' "$b" >> "$BR"
  done <<< "$REFS"

  # Ticket keys: only a prefix this project's tracker uses, read from its
  # branch names (`feat/ABC-123-x`, `abc-123-x`) and from commit subjects that
  # lead with a key (`ABC-123: …`, `[ABC-123] …`, `fix(ABC-123): …`). A
  # built-in ABC-123 shape also matches GPL-3, PHP-8 and GH-12, and a list of
  # public prefixes to skip is never complete; a prefix the project itself
  # uses is its tracker's. Other trackers' keys go in privateIdentifiers.
  PREFIXES=$( { printf '%s\n' "$REFS" | sed -E 's#^refs/(heads|remotes/[^/]+)/##' | tr '/' '\n' \
        | grep -oE '^[A-Za-z][A-Za-z0-9]{1,9}-[0-9]+' || true
      git -C "$P_ROOT" log -n 300 --all --format=%s 2>/dev/null \
        | grep -oE '^[[(]?[A-Z][A-Z0-9]{1,9}-[0-9]+|^[a-z]+\([A-Z][A-Z0-9]{1,9}-[0-9]+\)' || true
    } | sed -E 's/^[[(]//; s/^[a-z]+\(//; s/-[0-9]+.*$//' | tr '[:lower:]' '[:upper:]' | sort -u)
  if [ -n "$PREFIXES" ]; then
    while IFS= read -r m; do
      [ -n "$m" ] || continue
      grep -qxF -- "${m%%-*}" <<< "$PREFIXES" && hit ticket "$m"
    done < <(grep -owE '[A-Z][A-Z0-9]{1,9}-[0-9]{1,6}' "$SCAN" 2>/dev/null | sort -u || true)
  fi

  if [ -s "$LIT" ]; then
    cut -f2 "$LIT" > "$WORK/lit-values"
    grep -oiwF -f "$WORK/lit-values" "$SCAN" 2>/dev/null | sort -u \
      | awk -F'\t' 'NR == FNR { k[tolower($2)] = $1; next } { print (k[tolower($0)] == "" ? "configured" : k[tolower($0)]) "\t" $0 }' "$LIT" - >> "$HITS" || true
  fi
  if [ -s "$BR" ]; then
    sort -u "$BR" -o "$BR"
    grep -owF -f "$BR" "$SCAN" 2>/dev/null | sort -u | awk '{ print "branch\t" $0 }' >> "$HITS" || true
  fi

  SHAS=$(grep -owE '[0-9a-f]{7,40}' "$SCAN" 2>/dev/null | sort -u || true)
  if [ -n "$SHAS" ]; then
    TYPES=$(printf '%s\n' "$SHAS" | sed 's/$/^{commit}/' \
      | git -C "$P_ROOT" cat-file --batch-check='%(objecttype)' 2>/dev/null || true)
    while IFS=$'\t' read -r sha type; do
      [ "$type" = commit ] || continue
      if [ -n "$FORK_REMOTE" ] \
          && [ -n "$(git -C "$P_ROOT" branch -r --contains "$sha" --list "$FORK_REMOTE/*" 2>/dev/null || true)" ]; then
        continue
      fi
      hit commit "$sha"
    done < <(paste <(printf '%s\n' "$SHAS") <(printf '%s\n' "$TYPES"))
  fi
fi

[ -s "$HITS" ] || exit 0

# --- is any target public? ----------------------------------------------------
CACHE_HOME=""
if [ -n "$SESSION_ID" ] && [ -n "$P_ROOT" ]; then
  CACHE_HOME=$(session_home "$P_ROOT" 2>/dev/null || true)
  [ -z "$CACHE_HOME" ] || session_tracked "$CACHE_HOME" || CACHE_HOME=""
fi
visibility() {  # <host/o/r> -> public, private, internal or unknown
  local key="$1" host="${1%%/*}" or="${1#*/}" v=""
  if [ -n "$CACHE_HOME" ]; then
    # shellcheck disable=SC2016 # a jq program; $ev and $r are jq variables
    v=$(session_query "$CACHE_HOME" "$SESSION_ID" \
      '[$ev[] | select(.t == "visibility" and .repo == $r) | .value | strings] | last // empty' --arg r "$key")
  fi
  if [ -z "$v" ]; then
    local -a args=(api)
    [ "$host" = github.com ] || args+=(--hostname "$host")
    v=$(gh "${args[@]}" "repos/$or" --jq '.visibility // (if .private == true then "private" elif .private == false then "public" else empty end)' 2>/dev/null) || v=""
    case "$v" in
      public|private|internal)
        [ -z "$CACHE_HOME" ] || session_append "$CACHE_HOME" "$SESSION_ID" \
          "$(jq -nc --arg r "$key" --arg v "$v" '{t: "visibility", repo: $r, value: $v}')" 2>/dev/null || true ;;
      *) v=unknown ;;
    esac
  fi
  printf '%s\n' "$v"
}
EXPOSED=""
while IFS= read -r t; do
  [ -n "$t" ] || continue
  vis=$(visibility "$t")
  case "$vis" in
    public) EXPOSED="$EXPOSED$t (public)"$'\n' ;;
    unknown) EXPOSED="$EXPOSED$t (visibility unknown: gh could not tell, so treated as public)"$'\n' ;;
  esac
done <<< "$TARGETS"
[ -n "$EXPOSED" ] || exit 0

# A public project: its owner, name, pushed branches and pushed commits are
# public already. Only what origin does not have (a local-only branch, an
# unpushed commit) stays a leak; ticket keys and configured names stay too,
# since the tracker can be private when the code is not. An origin gh cannot
# tell about counts as private.
if [ -n "$ORIGIN_KEY" ] && grep -qE '^(repo|owner|branch|commit)'$'\t' "$HITS" \
    && [ "$(visibility "$ORIGIN_KEY")" = public ]; then
  ORIGIN_BRANCHES=$(sed -n 's#^refs/remotes/origin/##p' <<< "$REFS")
  : > "$WORK/kept"
  while IFS=$'\t' read -r kind m; do
    case "$kind" in
      repo|owner) continue ;;
      branch) if grep -qxF -- "$m" <<< "$ORIGIN_BRANCHES"; then continue; fi ;;
      commit)
        if [ -n "$(git -C "$P_ROOT" branch -r --contains "$m" --list 'origin/*' 2>/dev/null || true)" ]; then
          continue
        fi ;;
    esac
    printf '%s\t%s\n' "$kind" "$m" >> "$WORK/kept"
  done < "$HITS"
  mv -f "$WORK/kept" "$HITS"
  [ -s "$HITS" ] || exit 0
fi

describe_hits() {
  local kind m
  sort -u "$HITS" | while IFS=$'\t' read -r kind m; do
  case "$kind" in
    repo)       printf -- '- repository name "%s" -> "<app>" or "a private repo"\n' "$m" ;;
    owner)      printf -- '- owner or org "%s" -> "<org>"\n' "$m" ;;
    branch)     printf -- '- branch name "%s" -> a placeholder such as "fix/some-branch"\n' "$m" ;;
    commit)     printf -- '- commit "%s" (exists in this project) -> "<sha>"\n' "$m" ;;
    ticket)     printf -- '- ticket key "%s" -> "TICKET-1"\n' "$m" ;;
    session)    printf -- '- session link "%s" -> remove it\n' "$m" ;;
    home)       printf -- '- home path "%s" -> "<repo_root>" or a repo-relative path\n' "$m" ;;
    email)      printf -- '- email "%s" -> "<email>"\n' "$m" ;;
    credential) printf -- '- credential "%s..." -> remove it, and rotate it if it was ever posted\n' "${m:0:4}" ;;
    *)          printf -- '- private identifier "%s" (hooks.guardPublicPosts.privateIdentifiers) -> a placeholder such as "<redacted>"\n' "$m" ;;
  esac
  done
}
LIST=$(describe_hits)

pretool_deny "guard-public-posts.sh: this gh command would post identifiers from this project to a different repository:
$(printf '%s' "$EXPOSED" | sed 's/^/  /')
GitHub keeps edit history, so a scrub after posting does not undo a leak. Describe the problem against a placeholder or a fixture instead, replacing each match:
$LIST
Then re-run the command. If a match is not private (a public name that happens to equal one of this project's), re-run that gh command prefixed with MYSPEC_ALLOW_PUBLIC_POST=1 (on the gh command itself; elsewhere it does not count)."
