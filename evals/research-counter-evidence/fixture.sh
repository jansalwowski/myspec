#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../_fixtures/lib.sh"
cat > composer.json <<'JSON'
{"require": {"php": ">=8.3", "symfony/framework-bundle": "7.1.*"}, "require-dev": {"phpunit/phpunit": "^11.4"}}
JSON
mkdir -p .github/workflows
cat > .github/workflows/ci.yml <<'YAML'
name: ci
on: [push]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: composer install && vendor/bin/phpunit
YAML
git_commit_all "chore: app skeleton"
