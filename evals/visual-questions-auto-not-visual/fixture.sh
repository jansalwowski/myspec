#!/usr/bin/env bash
# Same workspace as visual-questions-auto: visualQuestions on, its rule installed.
set -euo pipefail
exec bash "$(dirname "${BASH_SOURCE[0]}")/../visual-questions-auto/fixture.sh"
