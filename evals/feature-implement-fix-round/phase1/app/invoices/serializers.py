from datetime import date

from app.invoices.due_dates import due_date, is_overdue
from app.invoices.models import Invoice


def invoice_to_dict(invoice: Invoice, today: date) -> dict:
    """Shape of one invoice in the GET /invoices/<number> response."""
    return {
        "number": invoice.number,
        "customer": invoice.customer.name,
        "issue_date": invoice.issue_date.isoformat(),
        "total": str(invoice.total),
        "status": invoice.status.value,
        "due_date": due_date(invoice).isoformat(),
        "overdue": is_overdue(invoice, today),
    }
