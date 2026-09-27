#!/usr/bin/env bash
# check-no-localhost-ports.sh
# Fails when a skill, blueprint, framework file, template, or example names a
# concrete local address with a port (localhost:3000, 127.0.0.1:8080, ...).
#
# myspec is stack-agnostic: a port copied from a skill or example reads as the
# rule in every downstream project, and the common defaults collide with the
# developer's own dev server. Name the variable and what it must point at
# instead ($SCRATCH_API_URL, "DATABASE_URL -> the scratch database").
#
# Repo-only check (CI). Not a shipped hook: downstream projects legitimately
# write their own localhost URLs.
#
# Usage: scripts/check-no-localhost-ports.sh   (from the repo root)

set -uo pipefail

PATTERN='(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]):[0-9]+'

# Files that show real output of a myspec-owned tool, whose port is chosen at
# runtime. Keep this list short; repo-relative, mirrors included.
ALLOW=(
  skills/brainstorm/visual-companion.md
  plugins/myspec/skills/brainstorm/visual-companion.md
)

EXCLUDES=()
for f in "${ALLOW[@]}"; do
  EXCLUDES+=(":(exclude)$f")
done

MATCHES=$(git grep --untracked -nE "$PATTERN" -- \
  skills blueprints framework-files templates examples plugins/myspec/skills \
  "${EXCLUDES[@]}" || true)

if [ -n "$MATCHES" ]; then
  echo "Concrete localhost:<port> addresses found:"
  echo "$MATCHES"
  echo
  echo "Name the variable and what it must point at instead of a host and port."
  echo "A file that shows a myspec tool's own runtime output can be added to ALLOW in $0."
  exit 1
fi

echo "OK: no localhost:<port> addresses in skills, blueprints, framework files, templates, or examples"
