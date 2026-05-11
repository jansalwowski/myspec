#!/usr/bin/env bash
#
# Bump the myspec version in lockstep across all five version sources.
# Does NOT commit, tag, or push — review the diff first, then do those manually.
#
# Usage: scripts/bump-version.sh X.Y.Z
#
set -euo pipefail

VERSION="${1:-}"

if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 X.Y.Z" >&2
  exit 1
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: version must be in X.Y.Z format (got: $VERSION)" >&2
  exit 1
fi

if ! command -v jq >/dev/null; then
  echo "Error: jq is required (https://jqlang.github.io/jq/)" >&2
  exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# Sanity check: refuse if the working tree has unrelated changes.
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Warning: working tree has uncommitted changes. Continue anyway? [y/N]" >&2
  read -r answer
  if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
    echo "Aborted." >&2
    exit 1
  fi
fi

bump_json_field() {
  local file="$1"
  local jq_expr="$2"
  if [[ ! -f "$file" ]]; then
    echo "Skip (missing): $file"
    return
  fi
  local tmp="${file}.tmp"
  jq --arg v "$VERSION" --arg r "v$VERSION" "$jq_expr" "$file" > "$tmp"
  mv "$tmp" "$file"
  echo "Bumped: $file"
}

# 1. Framework manifest — gates /myspec:update for consumer projects.
bump_json_field framework-files/manifest.json '.frameworkVersion = $v'

# 2. Claude plugin manifest.
bump_json_field .claude-plugin/plugin.json '.version = $v'

# 3. Claude marketplace manifest — both version AND git ref.
bump_json_field .claude-plugin/marketplace.json \
  '.plugins[0].version = $v | .plugins[0].source.ref = $r'

# 4. Codex plugin manifest.
bump_json_field .codex-plugin/plugin.json '.version = $v'

# 5. Local-source wrapper (used by .agents/plugins/marketplace.json).
bump_json_field plugins/myspec/.codex-plugin/plugin.json '.version = $v'

echo ""
echo "Bumped to v$VERSION. Modified files:"
git diff --name-only

cat <<EOF

Next steps (manual):
  git diff                                       # review
  git add -A
  git commit -m "chore: bump to v$VERSION"
  git tag v$VERSION
  git push && git push --tags
  gh release create v$VERSION --generate-notes   # optional
EOF
