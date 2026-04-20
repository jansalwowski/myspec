#!/usr/bin/env bash
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/hooks/mark-code-changed.sh"
