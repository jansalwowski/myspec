#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../_fixtures/lib.sh"

cat > composer.json <<'JSON'
{"require": {"php": ">=8.3", "symfony/messenger": "6.4.*", "symfony/doctrine-messenger": "6.4.*", "doctrine/dbal": "^3.8"}}
JSON
cat > composer.lock <<'JSON'
{"packages": [
  {"name": "symfony/messenger", "version": "v6.4.20"},
  {"name": "symfony/doctrine-messenger", "version": "v6.4.20"},
  {"name": "doctrine/dbal", "version": "3.9.4"}
]}
JSON

mkdir -p config/packages
cat > config/packages/messenger.yaml <<'YAML'
framework:
  messenger:
    transports:
      async: '%env(MESSENGER_TRANSPORT_DSN)%'
YAML
git_commit_all "chore: app skeleton"
