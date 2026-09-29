from app.invoices.models import Invoice


def invoice_to_dict(invoice: Invoice) -> dict:
    """Shape of one invoice in the GET /invoices/<number> response."""
    return {
        "number": invoice.number,
        "customer": invoice.customer.name,
        "issue_date": invoice.issue_date.isoformat(),
        "total": str(invoice.total),
        "status": invoice.status.value,
    }
