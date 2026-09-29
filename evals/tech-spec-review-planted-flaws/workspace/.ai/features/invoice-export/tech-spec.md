---
title: "Invoice CSV Export — Technical Specification"
status: draft
based_on_spec_version: 2
created: 2026-09-25
last_updated: 2026-09-25
---

# Invoice CSV Export — Technical Specification

## Architecture

A new `GET /invoices/export` endpoint in the invoices blueprint takes `start` and `end` query parameters, loads the matching invoices through the existing `InvoiceRepository`, and streams them back as `text/csv` with a `Content-Disposition: attachment` header.

### Reuse audit

| Candidate | Surface | Decision | Reason |
|-----------|---------|----------|--------|
| InvoiceRepository | app/invoices/repository.py | reuse | already loads invoices by date range |
| CSV serialisation helper | app/ | skip | the codebase has no shared CSV writer, so the feature adds its own |

## Key Interfaces

```python
def export_invoices(account_id: int, start: date, end: date) -> Iterator[str]: ...
```

## Implementation Steps

1. **Range parsing** — in `app/invoices/export_view.py`, parse `start` and `end` as ISO dates; return HTTP 400 when either is missing or `start > end`. (REQ-001)
2. **Query** — call `InvoiceRepository.by_issue_date(account_id, start, end)` (inclusive bounds) and collect the result list. (REQ-001, REQ-002)
3. **CSV writer** — add `app/invoices/csv_writer.py` with `rows_to_csv(invoices)`: writes the header `number, issue_date, customer, net_amount, currency, status`, then one line per invoice, quoting fields that contain commas. (REQ-003)
4. **Empty range** — when step 2 returns no invoices, render the export page with the flash message "No invoices in this period" and return no file. (REQ-005)
5. **Endpoint wiring** — register `GET /invoices/export` in `app/invoices/routes.py` and add the "Export" button to the invoice list template.
6. **Tests** — `tests/invoices/test_export.py`: range parsing, header row, one row per invoice, empty-range message.

## Edge Cases

- `start > end` → HTTP 400 with a validation message.
- Customer names containing commas or quotes → quoted per RFC 4180.
- Amounts are written with two decimals and a dot separator regardless of locale.

## File Inventory

| Path | Change |
|------|--------|
| app/invoices/export_view.py | new |
| app/invoices/csv_writer.py | new |
| app/invoices/routes.py | modify |
| app/templates/invoices/list.html | modify |
| tests/invoices/test_export.py | new |
