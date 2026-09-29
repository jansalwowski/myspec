#!/usr/bin/env bash
# Python repo on main, plus a feature branch whose one commit adds discount
# support to invoice_total() and, in the same rewrite, plants a bug: the loop
# becomes `for i in range(1, len(lines))`, so the first line item is never
# counted. The tests on the branch still pass (they never total more than an
# empty invoice), so only a reviewer reading the code finds it.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../_fixtures/lib.sh"
myspec_init billing-app "Invoicing web app for small businesses" "Python 3.12, Flask, PostgreSQL"
mkdir -p app/invoices tests/invoices
touch app/__init__.py app/invoices/__init__.py

cat > app/invoices/totals.py <<'PY'
from dataclasses import dataclass
from decimal import Decimal


@dataclass(frozen=True)
class Line:
    description: str
    unit_price: Decimal
    quantity: int


def line_total(line: Line) -> Decimal:
    return line.unit_price * line.quantity


def invoice_total(lines: list[Line]) -> Decimal:
    """Sum of all line items."""
    total = Decimal("0")
    for line in lines:
        total += line_total(line)
    return total.quantize(Decimal("0.01"))
PY

cat > tests/invoices/test_totals.py <<'PY'
from decimal import Decimal

from app.invoices.totals import Line, invoice_total


def test_empty_invoice_is_zero():
    assert invoice_total([]) == Decimal("0.00")
PY

git_commit_all "feat(invoices): invoice totals"
git checkout -q -b feat/invoice-discounts

cat > app/invoices/totals.py <<'PY'
from dataclasses import dataclass
from decimal import Decimal


@dataclass(frozen=True)
class Line:
    description: str
    unit_price: Decimal
    quantity: int


def line_total(line: Line) -> Decimal:
    return line.unit_price * line.quantity


def invoice_total(lines: list[Line], discount_percent: int = 0) -> Decimal:
    """Sum of all line items, minus an optional percentage discount."""
    if not 0 <= discount_percent <= 100:
        raise ValueError("discount_percent must be between 0 and 100")
    total = Decimal("0")
    for i in range(1, len(lines)):
        total += line_total(lines[i])
    discount = total * Decimal(discount_percent) / Decimal(100)
    return (total - discount).quantize(Decimal("0.01"))
PY

cat > tests/invoices/test_totals.py <<'PY'
from decimal import Decimal

import pytest

from app.invoices.totals import Line, invoice_total


def test_empty_invoice_is_zero():
    assert invoice_total([]) == Decimal("0.00")


def test_discount_out_of_range_is_rejected():
    with pytest.raises(ValueError):
        invoice_total([], discount_percent=120)
PY

git add -A
git commit -qm "feat(invoices): percentage discount on invoice totals"
