---
title: "Backend conventions"
updated: 2026-08-14
---

# Backend conventions

- Views live in `app/<domain>/*_view.py`; routes are registered in `app/<domain>/routes.py`.
- Data access goes through the domain repository (`app/<domain>/repository.py`); views never build queries.
- Every tabular download (CSV today, XLSX later) goes through `app/reporting/tabular_export.py` so column quoting, number formatting and the UTF-8 BOM stay consistent across reports. Do not hand-roll CSV writing in a feature module.
- Money is `Decimal`, formatted with two decimals and a dot separator.
