import csv
import io
from datetime import date

from flask import Response, abort, flash, redirect, request, url_for
from flask_login import current_user

from app.invoices.repository import InvoiceRepository

HEADER = ["number", "issue_date", "customer", "net_amount", "currency", "status"]


def _parse_range():
    try:
        start = date.fromisoformat(request.args["start"])
        end = date.fromisoformat(request.args["end"])
    except (KeyError, ValueError):
        abort(400, "start and end must be ISO dates")
    if start > end:
        abort(400, "start must not be after end")
    return start, end


def rows_to_csv(invoices) -> str:
    out = io.StringIO()
    writer = csv.writer(out)
    writer.writerow(HEADER)
    for inv in invoices:
        writer.writerow([
            inv.number,
            inv.issue_date.isoformat(),
            inv.customer_name,
            f"{inv.net_amount:.2f}",
            inv.currency,
            inv.status.value,
        ])
    return out.getvalue()


def export_invoices():
    start, end = _parse_range()
    invoices = InvoiceRepository().by_issue_date(current_user.account_id, start, end)
    if not invoices:
        flash("No invoices in this period")
        return redirect(url_for("invoices.list"))
    return Response(
        rows_to_csv(invoices),
        mimetype="text/csv",
        headers={"Content-Disposition": "attachment; filename=invoices.csv"},
    )
