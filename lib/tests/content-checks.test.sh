#!/usr/bin/env bash
# Function tests for lib/content-checks.sh (#263): the proposed content of a
# Write, Edit and MultiEdit (first occurrence, replace_all, an old_string the
# file lacks, trailing newlines kept, a create), the frontmatter region and
# issues, the reuse-audit state and issues with the per-file marker, the
# absolute-path findings and scope. The hooks and the Stop gate are tested
# end to end in hooks/tests/.
#
# Usage: content-checks.test.sh

set -uo pipefail

LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/hook-core.sh
. "$LIB/hook-core.sh"
# shellcheck source=lib/content-checks.sh
. "$LIB/content-checks.sh"

ROOT=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }
expect() {  # expect <want> <got> <desc>
  if [ "$1" = "$2" ]; then ok; else fail "$3 (want: $1; got: $2)"; fi
}

CUR="$ROOT/cur.md"
OUT="$ROOT/out.md"

# --- proposed_content ---------------------------------------------------------
printf 'a b a\nend\n' > "$CUR"
proposed_content '{"file_path":"x","content":"new\n"}' "$CUR" "$OUT"
expect write "$PROPOSED_KIND" "a Write is kind write"
expect "$(printf 'new\n' | od -c)" "$(od -c < "$OUT")" "a Write's content is written as is"

proposed_content '{"old_string":"a","new_string":"X"}' "$CUR" "$OUT"
expect edit "$PROPOSED_KIND" "an Edit is kind edit"
expect "X b a
end" "$(cat "$OUT")" "an Edit replaces the first occurrence"
expect "$(printf 'X b a\nend\n' | od -c)" "$(od -c < "$OUT")" "the trailing newline survives the round trip"

proposed_content '{"old_string":"a","new_string":"X","replace_all":true}' "$CUR" "$OUT"
expect "X b X
end" "$(cat "$OUT")" "replace_all replaces every occurrence"

proposed_content '{"old_string":"zzz","new_string":"X"}' "$CUR" "$OUT"
expect "a b a
end" "$(cat "$OUT")" "an old_string the file lacks leaves the content unchanged"

proposed_content '{"old_string":"a\nend","new_string":"a\nEND"}' "$CUR" "$OUT"
expect "a b a
END" "$(cat "$OUT")" "a multi-line old_string matches across lines"

proposed_content '{"old_string":"end\n","new_string":"end\n\n"}' "$CUR" "$OUT"
expect "$(printf 'a b a\nend\n\n' | od -c)" "$(od -c < "$OUT")" "trailing newlines in old and new strings are kept"

# shellcheck disable=SC2016 # the $1 is literal text inside the JSON string
proposed_content '{"old_string":"$1 & \\1","new_string":"[&]"}' "$CUR" "$OUT"
expect "a b a
end" "$(cat "$OUT")" "pattern characters in old_string are literal"
# shellcheck disable=SC2016 # literal $1 again
printf '$1 & \\1\n' > "$CUR"
# shellcheck disable=SC2016 # literal $1 again
proposed_content '{"old_string":"$1 & \\1","new_string":"[&] \\2"}' "$CUR" "$OUT"
expect '[&] \2' "$(cat "$OUT")" "pattern characters in new_string are literal"

printf 'a b a\nend\n' > "$CUR"
proposed_content '{"edits":[{"old_string":"a","new_string":"X"},{"old_string":"end","new_string":"END"}]}' "$CUR" "$OUT"
expect multi "$PROPOSED_KIND" "a MultiEdit is kind multi"
expect "X b a
END" "$(cat "$OUT")" "a MultiEdit applies its edits in order"

proposed_content '{"old_string":"","new_string":"made\n"}' "$ROOT/missing.md" "$OUT"
expect "made" "$(cat "$OUT")" "an empty old_string on a missing file creates the content"
proposed_content '{"old_string":"","new_string":"made\n"}' "$CUR" "$OUT"
expect "a b a
end" "$(cat "$OUT")" "an empty old_string on a non-empty file changes nothing"

proposed_content '{"file_path":"x"}' "$CUR" "$OUT" && fail "a call without content fails" || ok
proposed_content 'not json' "$CUR" "$OUT" && fail "unparseable input fails" || ok

# --- frontmatter --------------------------------------------------------------
printf -- '---\ntitle: T\nupdated: 2026-01-01\n---\nbody\n---\nmore\n' > "$CUR"
expect "---
title: T
updated: 2026-01-01
---" "$(frontmatter_region "$CUR")" "the region ends at the closing fence"
printf '# T\nbody\n' > "$CUR"
expect "# T" "$(frontmatter_region "$CUR")" "without a fence the region is line 1"
printf -- '---\ntitle: T\nnever closed\n' > "$CUR"
expect "---
title: T
never closed" "$(frontmatter_region "$CUR")" "an unclosed fence runs to the end"
expect "" "$(frontmatter_region "$ROOT/missing.md")" "a missing file has no region"

expect "" "$(printf -- '---\ntitle: T\nupdated: 2026-01-01\n---\n' > "$CUR"; frontmatter_issues "$CUR")" "valid frontmatter has no issues"
expect "missing frontmatter block entirely" "$(printf 'body\n' > "$CUR"; frontmatter_issues "$CUR")" "no fence at all"
expect "frontmatter must start on line 1 with '---' (a '---' block further down is not frontmatter)" "$(printf 'body\n---\ntitle: T\n---\n' > "$CUR"; frontmatter_issues "$CUR")" "a late block is not frontmatter"
printf -- '---\n---\n' > "$CUR"
expect "missing identity field: one of 'title', 'name', 'topic', 'id', 'type'
missing temporal field: one of 'updated', 'last_updated', 'created', 'started', 'date'" "$(frontmatter_issues "$CUR")" "an empty block reports both fields"
printf -- '---\ntitle: T\n' > "$CUR"
expect "frontmatter opened on line 1 is never closed with '---'
missing temporal field: one of 'updated', 'last_updated', 'created', 'started', 'date'" "$(frontmatter_issues "$CUR")" "an unclosed fence is reported with the fields it holds"
expect "Frontmatter issue in docs/a.md:
  - one
  - two
Fix the frontmatter before continuing (templates: .ai/.templates/)." "$(frontmatter_reason docs/a.md "one
two" .ai)" "the reason lists the issues and the templates"

frontmatter_scope .ai .ai/features/x/spec.md && ok || fail "an aiDir doc is in scope"
frontmatter_scope .ai .ai/ideas/x.md && fail "ideas/ is exempt" || ok
frontmatter_scope .ai docs/x.md && fail "a doc outside the aiDir is out" || ok
frontmatter_scope .ai .ai/features/x/seed.json && fail "a non-markdown aiDir file is out" || ok

# --- reuse audit --------------------------------------------------------------
SECTION='### Reuse audit

| Candidate | Surface | Decision | Reason |
|-----------|---------|----------|--------|
| Foo | lib | reuse | fits |'
printf '# T\n\n## Architecture\nx\n\n%s\n\n### Steps\n1. one\n' "$SECTION" > "$CUR"
expect "$SECTION" "$(reuse_audit_state "$CUR")" "the state is the section through the line before the next heading of its level"
printf '# T\n\n## Architecture\nx\n' > "$CUR"
expect "" "$(reuse_audit_state "$CUR")" "no section, no marker: empty state"
printf '# T\n<!-- myspec:reuse-audit skip: legacy -->\n## Architecture\nx\n' > "$CUR"
expect "<!-- myspec:reuse-audit skip: legacy -->" "$(reuse_audit_state "$CUR")" "the marker is part of the state"
expect "" "$(reuse_audit_issues "$CUR")" "a marker with a reason is valid"
printf '# T\n<!-- myspec:reuse-audit skip: -->\n' > "$CUR"
expect 'the <!-- myspec:reuse-audit skip: ... --> marker needs a reason after "skip:"' "$(reuse_audit_issues "$CUR")" "a marker without a reason is reported"
printf '# T\n\n%s\n' "$SECTION" > "$CUR"
expect "" "$(reuse_audit_issues "$CUR")" "a valid section passes"
printf '# T\n\n## Architecture\n' > "$CUR"
expect 'missing required section: "## Reuse audit" (or ### )' "$(reuse_audit_issues "$CUR")" "a missing section is reported"
printf '# T\n\n### Reuse audit\n\n| a | b | c | d |\n|---|---|---|---|\n| Foo | lib | skip | - |\n' > "$CUR"
expect "row 1: skip rows require a non-empty Reason" "$(reuse_audit_issues "$CUR")" "a skip row without a reason is reported"
reuse_audit_scope .ai/features/pay/tech-spec.md && ok || fail "a tech-spec is in scope"
reuse_audit_scope .ai/features/pay/sub/tech-spec.md && ok || fail "a nested tech-spec is in scope"
reuse_audit_scope .ai/features/pay/spec.md && fail "a spec.md is out" || ok
expect_in() { case "$2" in *"$1"*) ok ;; *) fail "$3" ;; esac; }
expect_in 'BLOCKED: x/tech-spec.md is missing a valid "## Reuse audit" section.' "$(reuse_audit_reason x/tech-spec.md diag)" "the reason opens with the friction-scan line"
expect_in "myspec:reuse-audit skip: <reason>" "$(reuse_audit_reason x/tech-spec.md diag)" "the reason names the marker"

# --- absolute paths -----------------------------------------------------------
printf 'see /Users/alice/x and /home/bob/y\nrel home/HomeFoo.vue\n-Users-alice-work\n' > "$CUR"
# The shapes match the home segment (what identifies the author); the rest
# of the path is the agent's to read in the file.
expect "1	/Users/alice
1	/home/bob
3	-Users-alice-work" "$(absolute_path_findings "$CUR")" "findings carry the line and the stripped match"
printf 'clean\n' > "$CUR"
expect "" "$(absolute_path_findings "$CUR")" "a clean file has no findings"
expect "replace with <repo_root>/src/a.ts" "$(absolute_path_hint /r/src/a.ts /r)" "a repo-internal path suggests <repo_root>"
expect "replace with <repo_root>" "$(absolute_path_hint /r /r)" "the root itself suggests <repo_root>"
expect "replace with ~/.claude-personal/projects/<encoded_cwd>/memory" "$(HOME=/Users/h absolute_path_hint /Users/h/.claude-personal/projects/-Users-h-proj/memory /r)" "a harness memory path suggests <encoded_cwd>"
R=$(absolute_paths_reason "the content proposed for" docs/a.md /r "line 2	/r/src/a.ts
")
expect_in "BLOCKED: the content proposed for docs/a.md contains absolute homedir paths" "$R" "the reason opens with the subject and the signature"
expect_in "  line 2: /r/src/a.ts" "$R" "the reason lists the finding"
expect_in "→ replace with <repo_root>/src/a.ts" "$R" "the reason carries the hint"

REPO="$ROOT/repo"
mkdir -p "$REPO"
git init -q -b main "$REPO"
printf '{"aiDir":"ai"}\n' > "$REPO/.myspec.json"
printf 'ignored/\n' > "$REPO/.gitignore"
absolute_paths_scope "$REPO" README.md && ok || fail "a doc at the root is in scope"
absolute_paths_scope "$REPO" ai/x.json && ok || fail "a file under the aiDir is in scope"
absolute_paths_scope "$REPO" .claude/x.sh && ok || fail "a file under .claude/ is in scope"
absolute_paths_scope "$REPO" docs/x.html && ok || fail "a file under docs/ is in scope"
absolute_paths_scope "$REPO" src/a.ts && fail "app code is out" || ok
absolute_paths_scope "$REPO" ignored/x.md && fail "a gitignored file is out" || ok
absolute_paths_scope "$REPO" .git/x.md && fail ".git/ is out" || ok
absolute_paths_scope "$REPO" lib/content-checks.sh && fail "the lib defining the shapes is out" || ok
printf '{}\n' > "$REPO/.myspec.json"
absolute_paths_scope "$REPO" .ai/x.json && ok || fail "no aiDir configured means .ai"
rm -f "$REPO/.myspec.json"
absolute_paths_scope "$REPO" .ai/x.json && fail "no .myspec.json means no aiDir tree" || ok

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
