#!/usr/bin/env bash
# A small Python project with no myspec setup yet. `init` must copy the
# framework documents through lib/aidir-render.mjs (#464).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../_fixtures/lib.sh"
mkdir -p app tests
cat > pyproject.toml <<'TOML'
[project]
name = "billing-app"
version = "0.1.0"
requires-python = ">=3.12"
dependencies = ["flask>=3.0", "psycopg[binary]>=3.1"]
TOML
cat > app/__init__.py <<'PY'
from flask import Flask


def create_app():
    app = Flask(__name__)

    @app.get("/health")
    def health():
        return {"ok": True}

    return app
PY
cat > tests/test_health.py <<'PY'
from app import create_app


def test_health():
    assert create_app().test_client().get("/health").json == {"ok": True}
PY
git_commit_all "chore: initial app"
