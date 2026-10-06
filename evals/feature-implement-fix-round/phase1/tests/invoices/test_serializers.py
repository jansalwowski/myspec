from datetime import date
from decimal import Decimal

from app.invoices.models import Customer, Invoice, InvoiceStatus
from app.invoices.serializers import invoice_to_dict


def test_invoice_to_dict_has_core_fields():
    invoice = Invoice("INV-1", Customer(1, "Acme"), date(2026, 9, 1), Decimal("10.00"), InvoiceStatus.ISSUED)
    assert invoice_to_dict(invoice, date(2026, 9, 2)) == {
        "number": "INV-1",
        "customer": "Acme",
        "issue_date": "2026-09-01",
        "total": "10.00",
        "status": "issued",
        "due_date": "2026-09-15",
        "overdue": False,
    }
