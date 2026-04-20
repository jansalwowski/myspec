#!/usr/bin/env bash
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/hooks/guard-git-branch.sh"
