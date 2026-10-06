---
title: "Invoice Due Dates -- Implementation Plan"
feature: invoice-due-dates
based_on_spec_version: 1
spec: .ai/features/invoice-due-dates/spec.md
tech_spec: .ai/features/invoice-due-dates/tech-spec.md
status: approved
created: 2026-09-26
last_updated: 2026-09-28
---

# Invoice Due Dates -- Implementation Plan

## Global Constraints

> Every task's requirements implicitly include this section.

- `tech-spec.md` §Constraints: "Python >= 3.12; no new dependencies."
- `spec.md` REQ-002: "A customer without payment terms gets 14 days."

## Execution Order

| Phase | Tasks | Mode | Depends On |
|-------|-------|------|------------|
| 1 | Task 1: Due-date rules, Task 2: API fields | sequential | — |

**Checkpoint probes:**
- Target: `python3 -c` in the checkout root, importing `app.invoices.serializers` → `invoice_to_dict(invoice, today)`
- Scratch env: none: the probes read no database, bucket or queue
- P1 [data]: `python3 -c "from datetime import date; from decimal import Decimal; from app.invoices.models import Customer, Invoice, InvoiceStatus; from app.invoices.serializers import invoice_to_dict; print(invoice_to_dict(Invoice('INV-1', Customer(1, 'Acme', 30), date(2026, 9, 1), Decimal('10.00'), InvoiceStatus.ISSUED), date(2026, 10, 2))['due_date'])"` → `2026-10-01`
- P2 [data]: the same call with `Customer(1, 'Acme', 30)`, today `date(2026, 10, 2)`, printing `['overdue']` → `True`
- P3 [data]: the same call with `InvoiceStatus.PAID`, today `date(2027, 1, 1)`, printing `['overdue']` → `False`

### Task 1: Due-date rules

**Spec contract (verbatim quotes — do NOT paraphrase):**
- `spec.md` REQ-001: "An invoice's due date is its issue date plus the customer's payment terms, in calendar days."
- `spec.md` REQ-002: "A customer without payment terms gets 14 days."
- `spec.md` REQ-003: "An issued invoice is overdue when today is after its due date."
- `spec.md` REQ-005: "A paid invoice is never overdue, whatever its due date."

**Files:**
- Create: `app/invoices/due_dates.py`
- Test: `tests/invoices/test_due_dates.py`

**Interfaces:**
- Consumes: `Invoice`, `InvoiceStatus` from `app/invoices/models.py`
- Produces: `due_date(invoice: Invoice) -> date`, `is_overdue(invoice: Invoice, today: date) -> bool` — Task 2 relies on both

**Depends on:** nothing

**Verify at phase review:** `pytest -q tests/invoices/test_due_dates.py`

- [x] **Step 1: Write the failing test** — `tests/invoices/test_due_dates.py`:

```python
from datetime import date
from decimal import Decimal

from app.invoices.due_dates import due_date, is_overdue
from app.invoices.models import Customer, Invoice, InvoiceStatus


def _invoice(terms, status=InvoiceStatus.ISSUED):
    return Invoice("INV-1", Customer(1, "Acme", terms), date(2026, 9, 1), Decimal("10.00"), status)


def test_due_date_adds_payment_terms():
    assert due_date(_invoice(30)) == date(2026, 10, 1)


def test_due_date_defaults_to_14_days():
    assert due_date(_invoice(None)) == date(2026, 9, 15)


def test_overdue_only_after_due_date():
    assert is_overdue(_invoice(30), date(2026, 10, 2))
    assert not is_overdue(_invoice(30), date(2026, 10, 1))


def test_paid_invoice_is_never_overdue():
    assert not is_overdue(_invoice(30, InvoiceStatus.PAID), date(2027, 1, 1))
```

- [x] **Step 2: Implement** — `app/invoices/due_dates.py`:

```python
from datetime import date, timedelta

from app.invoices.models import Invoice, InvoiceStatus

DEFAULT_PAYMENT_TERMS_DAYS = 14


def due_date(invoice: Invoice) -> date:
    terms = invoice.customer.payment_terms_days
    return invoice.issue_date + timedelta(days=DEFAULT_PAYMENT_TERMS_DAYS if terms is None else terms)


def is_overdue(invoice: Invoice, today: date) -> bool:
    return invoice.status is InvoiceStatus.ISSUED and today > due_date(invoice)
```

- [x] **Step 3: Commit** — `git commit -m "feat(invoice-due-dates): due-date rules"`

### Task 2: API fields

**Spec contract (verbatim quotes — do NOT paraphrase):**
- `spec.md` REQ-004: "The invoice API response carries the due date as an ISO 8601 date (YYYY-MM-DD) in a `due_date` field."
- `tech-spec.md` step 2: "`invoice_to_dict(invoice, today)` gains a `today: date` parameter and adds `\"due_date\": due_date(invoice).isoformat()` and `\"overdue\": is_overdue(invoice, today)`."

**Files:**
- Modify: `app/invoices/serializers.py`
- Modify: `tests/invoices/test_serializers.py`

**Touch only:** the `invoice_to_dict` signature and its returned dict; the one existing test's call and expected dict.

**Interfaces:**
- Consumes: `due_date(invoice: Invoice) -> date`, `is_overdue(invoice: Invoice, today: date) -> bool` — from Task 1
- Produces: `invoice_to_dict(invoice: Invoice, today: date) -> dict`

**Depends on:** Task 1

**Verify at phase review:** `pytest -q tests/invoices/test_serializers.py`

- [x] **Step 1: Update the test** — call `invoice_to_dict(invoice, date(2026, 9, 2))` and expect two more keys: `"due_date": "2026-09-15"`, `"overdue": False`.
- [x] **Step 2: Implement** — add the `today: date` parameter and the two keys, importing `due_date` and `is_overdue` from `app.invoices.due_dates`.
- [x] **Step 3: Commit** — `git commit -m "feat(invoice-due-dates): due date and overdue flag in the invoice API"`

## Spec Coverage

| Source | Requirement (verbatim) | Tasks |
|--------|------------------------|-------|
| spec.md REQ-001 | "An invoice's due date is its issue date plus the customer's payment terms, in calendar days." | T1 |
| spec.md REQ-002 | "A customer without payment terms gets 14 days." | T1 |
| spec.md REQ-003 | "An issued invoice is overdue when today is after its due date." | T1 |
| spec.md REQ-004 | "The invoice API response carries the due date as an ISO 8601 date (YYYY-MM-DD) in a `due_date` field." | T2 |
| spec.md REQ-005 | "A paid invoice is never overdue, whatever its due date." | T1 |
| spec.md AC-1 | "An invoice issued on 2026-09-01 to a customer with 30-day terms is due on 2026-10-01." | T1 |
| spec.md AC-2 | "An invoice issued on 2026-09-01 to a customer with no terms is due on 2026-09-15." | T1 |
| spec.md AC-3 | "On 2026-10-02, an issued invoice due on 2026-10-01 is reported as overdue; on 2026-10-01 it is not." | T1 |
| tech-spec.md step 1 | "Due-date rules" | T1 |
| tech-spec.md step 2 | "API fields" | T2 |

## Execution Log

- Ruling: run on the current branch feat/invoice-due-dates — the user chose it at Step 0 — cost if wrong: none, the branch is the feature branch
- Phase 1 review: APPROVED (Task 1, Task 2) — no findings
