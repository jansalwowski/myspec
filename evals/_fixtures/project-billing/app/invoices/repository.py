from datetime import date

from app.db import session
from app.invoices.models import Invoice


class InvoiceRepository:
    def by_issue_date(self, account_id: int, start: date, end: date) -> list[Invoice]:
        """All invoices of the account issued in [start, end], any status."""
        return (
            session.query(Invoice)
            .filter(Invoice.account_id == account_id)
            .filter(Invoice.issue_date.between(start, end))
            .order_by(Invoice.issue_date, Invoice.number)
            .all()
        )
