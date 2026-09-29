---
title: "Invoice CSV Export — Technical Specification"
status: approved
based_on_spec_version: 2
created: 2026-09-25
last_updated: 2026-09-26
---

# Invoice CSV Export — Technical Specification

## Architecture

`GET /invoices/export?start=&end=` in the invoices blueprint loads issued invoices through `InvoiceRepository` and streams them as `text/csv`.

### Reuse audit

| Candidate | Surface | Decision | Reason |
|-----------|---------|----------|--------|
| InvoiceRepository | app/invoices/repository.py | reuse | already loads invoices by date range |

## Implementation Steps

1. **Range parsing** — `app/invoices/export_view.py` parses `start`/`end` as ISO dates; HTTP 400 when missing or `start > end`. (REQ-001)
2. **Query** — `InvoiceRepository.by_issue_date(...)`, then drop invoices whose status is `DRAFT`. (REQ-002, REQ-004)
3. **CSV rows** — `rows_to_csv(invoices)` in `app/invoices/export_view.py` writes the header `number, issue_date, customer, net_amount, currency, status` and one line per invoice. (REQ-003)
4. **Empty range** — no invoices → flash "No invoices in this period", no file. (REQ-005)
5. **Tests** — `tests/invoices/test_export.py`.

## Edge Cases

- `start > end` → HTTP 400.
- Customer names with commas → quoted.

## File Inventory

| Path | Change |
|------|--------|
| app/invoices/export_view.py | new |
| tests/invoices/test_export.py | new |
