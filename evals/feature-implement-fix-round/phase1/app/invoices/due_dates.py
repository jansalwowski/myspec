from datetime import date, timedelta

from app.invoices.models import Invoice, InvoiceStatus

DEFAULT_PAYMENT_TERMS_DAYS = 14


def due_date(invoice: Invoice) -> date:
    terms = invoice.customer.payment_terms_days
    return invoice.issue_date + timedelta(days=DEFAULT_PAYMENT_TERMS_DAYS if terms is None else terms)


def is_overdue(invoice: Invoice, today: date) -> bool:
    """An issued invoice is overdue from its due date onwards."""
    return invoice.status is InvoiceStatus.ISSUED and today >= due_date(invoice)
