from datetime import date
from decimal import Decimal

from app.invoices.due_dates import due_date, is_overdue
from app.invoices.models import Customer, Invoice, InvoiceStatus


def _invoice(terms, status=InvoiceStatus.ISSUED):
    return Invoice("INV-1", Customer(1, "Acme", terms), date(2026, 9, 1), Decimal("10.00"), status)


def test_due_date_adds_payment_terms():
    assert due_date(_invoice(30)) == date(2026, 10, 1)


def test_due_date_defaults_to_14_days():
    assert due_date(_invoice(None)) == date(2026, 9, 15)


def test_overdue_only_after_due_date():
    assert is_overdue(_invoice(30), date(2026, 10, 2))
    assert not is_overdue(_invoice(30), date(2026, 10, 1))


def test_paid_invoice_is_never_overdue():
    assert not is_overdue(_invoice(30, InvoiceStatus.PAID), date(2027, 1, 1))
