from flask import Response

from app.customers.repository import CustomerRepository
from app.reporting.tabular_export import stream_csv

COLUMNS = ["id", "name", "email", "open_balance"]


def customer_report(account_id: int) -> Response:
    customers = CustomerRepository().for_account(account_id)
    rows = ((c.id, c.name, c.email, c.open_balance) for c in customers)
    return Response(
        stream_csv(COLUMNS, rows),
        mimetype="text/csv",
        headers={"Content-Disposition": "attachment; filename=customers.csv"},
    )
