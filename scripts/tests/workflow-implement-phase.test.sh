#!/usr/bin/env bash
# Runs the stub-runtime test for workflows/implement-phase.js (#247).
# Usage: workflow-implement-phase.test.sh [path-to-workflow-script]
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec node "$HERE/workflow-implement-phase.test.mjs" "$@"
