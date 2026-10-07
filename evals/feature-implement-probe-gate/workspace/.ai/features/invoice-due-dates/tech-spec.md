---
title: "Invoice Due Dates — Technical Specification"
status: approved
based_on_spec_version: 1
verification_mode: data
created: 2026-09-24
last_updated: 2026-09-25
---

# Invoice Due Dates — Technical Specification

## Architecture

Two pure functions in a new module compute the due date and the overdue flag. The existing serializer adds both to the invoice response. No schema change: `Customer.payment_terms_days` already exists and is nullable.

## Key Interfaces

```python
DEFAULT_PAYMENT_TERMS_DAYS = 14

def due_date(invoice: Invoice) -> date: ...
def is_overdue(invoice: Invoice, today: date) -> bool: ...
```

## Implementation Steps

1. **Due-date rules** — add `app/invoices/due_dates.py` with `DEFAULT_PAYMENT_TERMS_DAYS = 14`, `due_date(invoice)` (issue date plus `customer.payment_terms_days`, or the default when it is `None`) and `is_overdue(invoice, today)` (`True` only when the status is `ISSUED` and `today > due_date(invoice)`; a paid or draft invoice is never overdue). Tests in `tests/invoices/test_due_dates.py` cover AC-1, AC-2, AC-3 and a paid invoice past its due date.
2. **API fields** — in `app/invoices/serializers.py`, `invoice_to_dict(invoice, today)` gains a `today: date` parameter and adds `"due_date": due_date(invoice).isoformat()` and `"overdue": is_overdue(invoice, today)`. Update `tests/invoices/test_serializers.py`.

## Edge Cases

- `payment_terms_days == 0` → due on the issue date.
- A draft invoice has a due date in the response but is never overdue.

## File Inventory

| Path | Change |
|------|--------|
| app/invoices/due_dates.py | new |
| app/invoices/serializers.py | modify |
| tests/invoices/test_due_dates.py | new |
| tests/invoices/test_serializers.py | modify |

## Test Hooks

- **Target:** `python3 -c` in the checkout root, importing `app.invoices.serializers` (no server; the module is the entry point)
- **Contract surface:** `invoice_to_dict(invoice, today)` and its `due_date` / `overdue` keys
- **Scratch environment:** none: the probes read no database, bucket or queue

## Constraints

- Python >= 3.12; no new dependencies.
