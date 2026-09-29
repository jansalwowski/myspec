from datetime import date
from decimal import Decimal
from types import SimpleNamespace

from app.invoices.export_view import HEADER, rows_to_csv
from app.invoices.models import InvoiceStatus


def _invoice(number, status=InvoiceStatus.ISSUED):
    return SimpleNamespace(
        number=number,
        issue_date=date(2026, 9, 1),
        customer_name="Acme, Inc.",
        net_amount=Decimal("120.50"),
        currency="EUR",
        status=status,
    )


def test_header_row():
    assert rows_to_csv([]).splitlines()[0] == ",".join(HEADER)


def test_one_row_per_invoice_and_quoting():
    lines = rows_to_csv([_invoice("INV-1"), _invoice("INV-2")]).splitlines()
    assert len(lines) == 3
    assert '"Acme, Inc."' in lines[1]
