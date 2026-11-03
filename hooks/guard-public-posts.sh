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
# a quoted body or a heredoc is not one), `gh issue|pr create|comment|edit|
# review|close`, and `gh api` with a POST, PATCH or PUT (or a field, which makes
# gh POST) to `repos/<o>/<r>/issues…` or `repos/<o>/<r>/pulls…`. A
# `gh api graphql` mutation and a gh run inside `bash -c` are not seen.
#
# WHERE IT GOES: the URL operand (`gh issue comment https://<host>/<o>/<r>/
# issues/1`), else `-R`/`--repo`, else `GH_REPO=`, else the `gh api` endpoint,
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
#   - a Claude Code session link, a home directory path (/Users/<name>,
#     /home/<name>), an email address, a credential-shaped token, and a ticket
#     key such as ABC-123 (a public standard's prefix, UTF-8, RFC-9110, is
#     skipped): the shapes scripts/triage/redaction-check.mjs checks after the
#     fact on the myspec repo itself
#   - each entry of the setting hooks.guardPublicPosts.privateIdentifiers:
#     a literal (case-insensitive, whole word) or, written `/…/`, an extended
#     regex (codenames, a ticket prefix the shape above skips)
# When the target is one of the project's own remotes (the project is a fork
# of it), branch names and commits that remote already has are public there
# and skipped.
#
# VISIBILITY: asked only when something matched, with one
# `gh api repos/<o>/<r>` call per target and session, cached as a
# `visibility` event in the session-state file (lib/session-event.sh; only in
# a checkout that has one, a myspec project). Private and internal targets are
# allowed. When gh cannot answer (offline, not logged in, rate-limited), the
# target is treated as public: a leak cannot be taken back and a false block
# costs one re-run with the override, so the unknown case errs toward the
# check. Infrastructure alone never blocks: a post with no match is allowed
# whatever gh says, and without gh on PATH the post cannot run at all.
#
# Escape hatch: MYSPEC_ALLOW_PUBLIC_POST=1 as a command prefix, the same idiom
# as guard-worktree-context.sh's MYSPEC_ALLOW_MAIN_CHECKOUT. Advertised in the
# block message: a match can be a public name that happens to equal a private
# one, and only the agent reading the text can tell.
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
if [ ! -f "$(dirname "$HOOK_CORE")/command-scan.sh" ] || [ ! -f "$(dirname "$HOOK_CORE")/session-event.sh" ]; then
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
OVERRIDE_RE='(^|[[:space:]])MYSPEC_ALLOW_PUBLIC_POST=1[[:space:]]'
[[ $COMMAND =~ $OVERRIDE_RE ]] && exit 0
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

# parse_gh <word>... (keep-mode words after `gh`) -> G_POST=1 for a post,
# G_REPO (where it says it goes, if it does), G_TEXT (its inline text) and
# G_FILES (the files it sends, one per line).
parse_gh() {
  local n=$# i=0 w v group="" verb="" method="" endpoint="" fields=0 host="" url_repo="" re
  local -a a=("$@")
  G_POST=0 G_REPO="" G_TEXT="" G_FILES=""
  while [ "$i" -lt "$n" ]; do
    decode_word_to w "${a[i]}"
    v=""
    [ $((i + 1)) -ge "$n" ] || decode_word_to v "${a[i + 1]}"
    if [ -z "$group" ]; then
      case "$w" in issue|pr|api) group="$w"; i=$((i + 1)); continue ;; *) return 0 ;; esac
    fi
    case "$group:$w" in
      *:-R|*:--repo) G_REPO="$v"; i=$((i + 2)); continue ;;
      *:--repo=*) G_REPO="${w#*=}" ;;
      api:-X|api:--method) method="$v"; i=$((i + 2)); continue ;;
      api:--method=*) method="${w#*=}" ;;
      api:-X*) method="${w#-X}" ;;
      api:-f|api:--raw-field) fields=1; G_TEXT="$G_TEXT${v#*=}"$'\n'; i=$((i + 2)); continue ;;
      api:-F|api:--field)
        fields=1
        case "${v#*=}" in
          @*) v="${v#*=}"; G_FILES="$G_FILES${v#@}"$'\n' ;;
          *) G_TEXT="$G_TEXT${v#*=}"$'\n' ;;
        esac
        i=$((i + 2)); continue ;;
      api:--input) fields=1; G_FILES="$G_FILES$v"$'\n'; i=$((i + 2)); continue ;;
      api:--hostname) host="$v"; i=$((i + 2)); continue ;;
      api:-H|api:--header|api:-q|api:--jq|api:-t|api:--template|api:-p|api:--preview|api:--cache)
        i=$((i + 2)); continue ;;
      api:-*) ;;
      api:*) [ -n "$endpoint" ] || endpoint="$w" ;;
      *:-t|*:--title|*:-b|*:--body|*:-c|*:--comment) G_TEXT="$G_TEXT$v"$'\n'; i=$((i + 2)); continue ;;
      *:--title=*|*:--body=*|*:--comment=*) G_TEXT="$G_TEXT${w#*=}"$'\n' ;;
      *:-F|*:--body-file) G_FILES="$G_FILES$v"$'\n'; i=$((i + 2)); continue ;;
      *:--body-file=*) G_FILES="$G_FILES${w#*=}"$'\n' ;;
      *:-*) ;;
      *)
        if [ -z "$verb" ]; then
          verb="$w"
        else
          re='^https?://[^/]+/[^/]+/[^/]+/(issues|pull)/[0-9]+'
          [[ $w =~ $re ]] && url_repo="$w"
        fi ;;
    esac
    i=$((i + 1))
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
  case "$verb" in create|comment|edit|review|close) G_POST=1 ;; *) return 0 ;; esac
  [ -z "$url_repo" ] || G_REPO="$url_repo"
}

ORIGIN_KEY=""
if [ -n "$P_ROOT" ]; then
  ORIGIN_KEY=$(repo_key "$(git -C "$P_ROOT" remote get-url origin 2>/dev/null || true)" 2>/dev/null || true)
fi

# Walk the segments: track `cd`, collect each post that leaves this project.
TARGETS=""
TEXT=""
FILES=""
DIR="$START_DIR"
w0="" w1=""
GH_REPO_RE='(^|[[:space:]])GH_REPO=([^[:space:]]+)'
SEGMENTS=$(printf '%s\n' "$COMMAND" | sanitize_command keep | split_segments)
while IFS=$'\t' read -r _sep seg; do
  gh_repo_env=""
  if [[ $seg =~ $GH_REPO_RE ]]; then
    decode_word_to gh_repo_env "${BASH_REMATCH[2]}"
  fi
  strip_command_prefix_to seg "$seg"
  W=()
  read -r -a W <<< "$seg" || true
  [ "${#W[@]}" -gt 0 ] || continue
  decode_word_to w0 "${W[0]}"
  case "$w0" in
    cd)
      if [ "${#W[@]}" -gt 1 ]; then
        decode_word_to w1 "${W[1]}"
        case "$w1" in /*) cand="$w1" ;; *) cand="$DIR/$w1" ;; esac
        [ ! -d "$cand" ] || DIR="$cand"
      fi
      continue ;;
    gh|*/gh) ;;
    *) continue ;;
  esac
  [ "${#W[@]}" -gt 1 ] || continue
  parse_gh "${W[@]:1}"
  [ "$G_POST" = 1 ] || continue
  target=""
  if [ -n "$G_REPO" ]; then
    target=$(repo_key "$G_REPO" 2>/dev/null || true)
  elif [ -n "$gh_repo_env" ]; then
    target=$(repo_key "$gh_repo_env" 2>/dev/null || true)
  else
    target=$(dir_target "$DIR" 2>/dev/null || true)
  fi
  [ -n "$target" ] || continue
  [ "$target" != "$ORIGIN_KEY" ] || continue
  case $'\n'"$TARGETS" in *$'\n'"$target"$'\n'*) ;; *) TARGETS="$TARGETS$target"$'\n' ;; esac
  TEXT="$TEXT$G_TEXT"
  while IFS= read -r f; do
    if [ -z "$f" ] || [ "$f" = - ]; then continue; fi
    case "$f" in /*) ;; *) f="$DIR/$f" ;; esac
    FILES="$FILES$f"$'\n'
  done <<< "$G_FILES"
done <<< "$SEGMENTS"
[ -n "$TARGETS" ] || exit 0

# `$(cat <file>)` / `$(< <file>)` inside an inline body.
CAT_RE='\$\((cat[[:space:]]+|<[[:space:]]*)([^)[:space:]]+)\)'
rest="$TEXT"
while [[ $rest =~ $CAT_RE ]]; do
  f="${BASH_REMATCH[2]}"
  f="${f#[\'\"]}"; f="${f%[\'\"]}"
  case "$f" in /*) ;; *) f="$DIR/$f" ;; esac
  FILES="$FILES$f"$'\n'
  rest="${rest#*"${BASH_REMATCH[0]}"}"
done

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
while IFS= read -r m; do
  [ -n "$m" ] || continue
  case "${m%%-*}" in
    AC|AES|ANSI|CVE|CWE|ECMA|ES|FR|GHSA|GPT|HTTP|IEEE|IPV|ISO|MD|NFR|PEP|POSIX|PSR|REQ|RFC|RSA|SC|SHA|TC|TICKET|TLS|US|UTF|WCAG|X) continue ;;
  esac
  hit ticket "$m"
done < <(grep -owE '[A-Z][A-Z0-9]{1,9}-[0-9]{1,6}' "$SCAN" 2>/dev/null | sort -u || true)

# --- the project's own identifiers --------------------------------------------
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
Then re-run the command. If a match is not private (a public name that happens to equal one of this project's), re-run it prefixed with MYSPEC_ALLOW_PUBLIC_POST=1."
