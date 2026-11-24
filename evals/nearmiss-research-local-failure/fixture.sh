#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../_fixtures/lib.sh"
myspec_init

mkdir -p app/invoices tests
cat > app/invoices/due.py <<'PY'
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo


def due_date(invoice: dict) -> datetime:
    tz = ZoneInfo(invoice["customer"]["tz"])
    return datetime.fromisoformat(invoice["issued_at"]).astimezone(tz) + timedelta(days=invoice["terms_days"])
PY
cat > tests/test_due_dates.py <<'PY'
from app.invoices.due import due_date


def test_net_30():
    invoice = {"issued_at": "2026-01-01T10:00:00+00:00", "terms_days": 30, "customer": {"timezone": "Europe/Warsaw"}}
    assert due_date(invoice).day == 31
PY
git_commit_all "chore: initialise myspec"
