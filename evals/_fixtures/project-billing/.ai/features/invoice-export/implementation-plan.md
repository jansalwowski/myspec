---
feature: invoice-export
planned_against: 0000000000000000000000000000000000000000
created: 2026-09-26
---

# Implementation Plan: invoice-export

## Execution Order

| Phase | Tasks | Mode |
|-------|-------|------|
| 1 | T1, T2 | sequential |

## Tasks

### T1: Export view with range parsing, draft filter and CSV rows
- [x] Write failing tests for range parsing, header row and draft exclusion
- [x] Implement `app/invoices/export_view.py`
- [x] Tests pass

### T2: Empty-range message
- [x] Write failing test for the empty range
- [x] Implement the flash message
- [x] Tests pass
