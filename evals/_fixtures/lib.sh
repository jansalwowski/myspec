#!/usr/bin/env bash
# Shared scaffold helpers for evals/<case>/fixture.sh.
#
# A case's fixture.sh sources this file, then builds its workspace:
#
#   . "$(dirname "${BASH_SOURCE[0]}")/../_fixtures/lib.sh"
#   myspec_init
#   add_feature feature-invoice-export-flawed invoice-export draft
#
# `claude plugin eval --scaffold` runs fixture.sh as the maintainer, outside
# the agent sandbox, with the empty run workspace as the working directory.
# Everything below writes relative to that directory.
#
# myspec_init mirrors what the `init` skill writes for a project that answered
# "yes" to the harness config (since 3.0 init copies no hook, lib or
# settings.json: the plugin runs its hooks itself). It writes no
# .claude/settings.json hooks either: the eval sandbox has not loaded plugin
# hooks (see evals/README.md), and project hooks would run outside the sandbox
# and make runs slower and less repeatable.
# Framework files are copied from the plugin under test, so a change to
# framework-files/ is exercised by every case.
#
# The run never loads the CLAUDE.md and .claude/rules/ written here. After
# changing this file or a fixture, run evals/_fixtures/project-instructions.sh
# so each case.yaml carries them as append_system_prompt (evals/README.md,
# "Project instructions").

set -euo pipefail

FIXTURES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$FIXTURES_DIR/../.." && pwd)"
AI_DIR=".ai"

# Copy one framework document, resolving ${aiDir} the way init does for docs.
_copy_doc() {
  mkdir -p "$(dirname "$2")"
  sed "s#\${aiDir}#$AI_DIR#g" "$1" > "$2"
}

# myspec_init [project-name] [description] [tech-stack]
myspec_init() {
  local name="${1:-billing-app}" desc="${2:-Invoicing web app for small businesses}" stack="${3:-Python 3.12, Flask, PostgreSQL}"
  local manifest="$PLUGIN_ROOT/framework-files/manifest.json"
  local version migrations
  version=$(sed -n 's/.*"frameworkVersion": *"\([^"]*\)".*/\1/p' "$manifest" | head -1)
  migrations=$(awk '/"migrations"/{on=1} on{print} on&&/\]/{exit}' "$manifest" | sed '1s/.*\[/[/' | tr -d '\n' | tr -s ' ' | sed 's/,[[:space:]]*$//')

  cat > .myspec.json <<JSON
{
  "aiDir": "$AI_DIR",
  "frameworkVersion": "$version",
  "project": {
    "name": "$name",
    "description": "$desc",
    "techStack": "$stack"
  },
  "migrations": $migrations
}
JSON

  cat > CLAUDE.md <<MD
# $name

$desc. Stack: $stack.

<!-- BEGIN myspec:paths -->
## myspec paths

Skill instructions reference \`\${aiDir}/\`. Resolve to **\`$AI_DIR/\`** (configured in \`.myspec.json\`).
<!-- END myspec:paths -->
MD

  local ai="$AI_DIR" t="$PLUGIN_ROOT/framework-files/templates"
  mkdir -p "$ai/features" "$ai/memory/procedural" "$ai/memory/semantic" "$ai/memory/episodic" \
    "$ai/memory/sessions/archive" "$ai/.templates" "$ai/ideas/processed" \
    "$ai/conventions" "$ai/decisions" "$ai/plans"
  cp "$PLUGIN_ROOT/scaffolding/features/index.yaml" "$ai/features/index.yaml"
  cat > "$ai/memory/index.md" <<'MD'
---
type: index
updated: 2026-09-01
---

# Memory Index (Layer 1)

Global anchors loaded every session. Layer 2 indexes: procedural/, semantic/, episodic/.

| ID | Hook | Anchor |
|----|------|--------|
MD
  for kind in procedural semantic episodic; do
    _copy_doc "$t/index-$kind.md" "$ai/memory/$kind/index.md"
    _copy_doc "$t/memory-$kind.md" "$ai/.templates/memory-$kind.md"
  done
  _copy_doc "$t/session-log.md" "$ai/.templates/session-log.md"
  for f in INTAKE-INSTRUCTIONS.md PRIORITY-LISTING.md PROCESSING-INSTRUCTIONS.md; do
    _copy_doc "$PLUGIN_ROOT/scaffolding/ideas/$f" "$ai/ideas/$f"
  done
  touch "$ai/memory/sessions/archive/.gitkeep" "$ai/ideas/processed/.gitkeep" \
    "$ai/conventions/.gitkeep" "$ai/decisions/.gitkeep" "$ai/plans/.gitkeep"
  _copy_doc "$PLUGIN_ROOT/framework-files/anti-patterns.md" "$ai/anti-patterns.md"
  _copy_doc "$PLUGIN_ROOT/framework-files/pre-flight.md" "$ai/pre-flight.md"
  # Added in 2.10.0 (#241). release-check re-runs an older tag with HEAD's evals/
  # copied in, and that tree has no such file, so copy it only where it exists.
  if [ -f "$PLUGIN_ROOT/framework-files/work-isolation.md" ]; then
    _copy_doc "$PLUGIN_ROOT/framework-files/work-isolation.md" "$ai/work-isolation.md"
  fi

  local rule
  for rule in "$PLUGIN_ROOT"/framework-files/rules/*.md; do
    _copy_doc "$rule" ".claude/rules/$(basename "$rule")"
  done
  printf '.claude/state/\n' > .gitignore
}

# add_feature <fixture-dir> <feature-name> <status> [phase] [priority]
# Copies evals/_fixtures/<fixture-dir>/ into ${aiDir}/features/<feature-name>/
# and appends the manifest entry.
add_feature() {
  local src="$FIXTURES_DIR/$1" name="$2" status="$3" phase="${4:-1}" priority="${5:-P2}"
  [ -d "$src" ] || { echo "add_feature: no fixture dir $src" >&2; return 1; }
  mkdir -p "$AI_DIR/features/$name"
  cp -R "$src/." "$AI_DIR/features/$name/"
  register_feature "$name" "$status" "$phase" "$priority"
}

# register_feature <feature-name> <status> [phase] [priority]
# Appends a manifest entry; the title comes from the feature's spec.md.
register_feature() {
  local name="$1" status="$2" phase="${3:-1}" priority="${4:-P2}" title=""
  local index="$AI_DIR/features/index.yaml"
  if [ -f "$AI_DIR/features/$name/spec.md" ]; then
    title=$(sed -n 's/^title: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$AI_DIR/features/$name/spec.md" | head -1)
  fi
  sed -i.bak 's/^features: \[\]$/features:/' "$index" && rm -f "$index.bak"
  cat >> "$index" <<YAML
  - name: $name
    title: "${title:-$name}"
    status: $status
    phase: $phase
    priority: $priority
    depends-on: []
YAML
}

# copy_tree <fixture-dir> — copy evals/_fixtures/<fixture-dir>/ into the workspace root.
copy_tree() {
  local src="$FIXTURES_DIR/$1"
  [ -d "$src" ] || { echo "copy_tree: no fixture dir $src" >&2; return 1; }
  cp -R "$src/." .
}

# git_commit_all <message> — initialise a repo on main (if needed) and commit everything.
git_commit_all() {
  if [ ! -d .git ]; then
    git init -q -b main .
    git config user.email eval@example.invalid
    git config user.name "Eval Fixture"
  fi
  git add -A
  git commit -qm "$1"
}
